import SwiftUI
import BudgetModels

/// A transaction's detail: recategorize, note, mark reviewed, set privacy, and
/// the couples layer — emoji reactions and a comment thread (Honeydue).
struct TransactionDetailView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var tx: Transaction
    @State private var comments: [TransactionComment] = []
    @State private var reactions: [TransactionReaction] = []
    @State private var note: String
    @State private var newComment = ""
    @State private var loaded = false
    @State private var rulePrompt: RulePrompt?

    /// Offered after a recategorize when other transactions share the merchant.
    private struct RulePrompt { let categoryID: UUID; let count: Int }

    private let reactionChoices = ["👍", "🎉", "❤️", "😂", "💸", "✅"]

    init(transaction: Transaction) {
        _tx = State(initialValue: transaction)
        _note = State(initialValue: transaction.note ?? "")
    }

    private var store: TransactionStore { env.transactionStore }
    private var isOwner: Bool { tx.ownerMemberID == env.session.member?.id }

    var body: some View {
        List {
            headerSection
            detailsSection
            reactionsSection
            commentsSection
        }
        .navigationTitle(tx.merchantName ?? tx.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Always file \(tx.merchantName ?? tx.name) here?",
                            isPresented: Binding(get: { rulePrompt != nil }, set: { if !$0 { rulePrompt = nil } }),
                            titleVisibility: .visible, presenting: rulePrompt) { prompt in
            Button("Apply to \(prompt.count) more from this merchant") {
                Task { await store.applyRule(transactionID: tx.id, categoryID: prompt.categoryID) }
            }
            Button("Just this one", role: .cancel) {}
        } message: { prompt in
            Text("Future transactions from this merchant will go to \(env.categoryStore.name(for: prompt.categoryID)) too. Ones you've categorized yourself won't change.")
        }
        .task {
            guard !loaded else { return }
            if let detail = await store.detail(tx.id) {
                tx = detail.transaction
                note = detail.transaction.note ?? ""
                comments = detail.comments
                reactions = detail.reactions
            }
            loaded = true
        }
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 6) {
                Text(signedCurrency(tx))
                    .font(.system(.largeTitle, design: .rounded).bold())
                    .foregroundStyle(tx.isInflow ? .green : .primary)
                Text(tx.name).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(tx.date.formatted(date: .complete, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var detailsSection: some View {
        Section {
            // A native menu Picker, not Menu { } label: { LabeledContent }: inside a
            // List row on iOS 26 that Menu expanded to fill the section, leaving a
            // ~330pt gap under "Category". Picker sizes like any other row.
            Picker("Category", selection: Binding(
                get: { tx.categoryID },
                set: { newValue in
                    Task {
                        let request: UpdateTransactionRequest = newValue.map { .init(categoryID: $0) }
                            ?? .init(clearCategory: true)
                        if let u = await store.update(tx.id, request) { tx = u }
                        if let categoryID = newValue, let preview = await store.rulePreview(for: tx.id),
                           preview.matchCount > 0 {
                            rulePrompt = RulePrompt(categoryID: categoryID, count: preview.matchCount)
                        }
                    }
                })) {
                Label("Uncategorized", systemImage: "xmark.circle").tag(UUID?.none)
                ForEach(env.categoryStore.categoriesByGroup(), id: \.group.id) { entry in
                    Section(entry.group.name) {
                        ForEach(entry.categories) { category in
                            Label(category.name, systemImage: category.icon ?? "tag")
                                .tag(Optional(category.id))
                        }
                    }
                }
            }
            .pickerStyle(.menu)

            // View-destination link, not value-based: this view is also shown
            // inside Home's stack, where value links don't fire.
            NavigationLink {
                SplitEditorView(transaction: tx) { tx = $0 }
            } label: {
                LabeledContent {
                    Text(tx.isSplit ? "\(tx.splits.count) categories" : "")
                } label: {
                    Label("Split", systemImage: "square.split.2x1")
                }
            }

            HStack {
                Text("Note")
                Spacer()
                TextField("Add a note", text: $note)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { Task { if let u = await store.update(tx.id, .init(note: note)) { tx = u } } }
            }

            Toggle("Reviewed", isOn: Binding(
                get: { tx.isReviewed },
                set: { value in Task { if let u = await store.update(tx.id, .init(isReviewed: value)) { tx = u } } }))

            if isOwner {
                Toggle("Private (hide from partner)", isOn: Binding(
                    get: { tx.visibility == .private },
                    set: { value in
                        Task { if let u = await store.update(tx.id, .init(visibility: value ? .private : .shared)) { tx = u } }
                    }))
            }
        }
    }

    private var reactionsSection: some View {
        Section("Reactions") {
            HStack(spacing: 4) {
                ForEach(reactionChoices, id: \.self) { emoji in
                    let mine = reactions.contains { $0.emoji == emoji && $0.memberID == env.session.member?.id }
                    Button {
                        Task { if let r = await store.toggleReaction(tx.id, emoji: emoji) { reactions = r } }
                    } label: {
                        Text(emoji)
                            .font(.title2)
                            .padding(6)
                            .background(mine ? Color.accentColor.opacity(0.25) : Color.clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            ForEach(groupedReactions, id: \.emoji) { entry in
                HStack {
                    Text(entry.emoji)
                    Text(entry.members.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var commentsSection: some View {
        Section("Comments") {
            if comments.isEmpty {
                Text("No comments yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(memberName(comment.memberID)).font(.caption.bold())
                        Spacer()
                        Text(comment.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(comment.body)
                }
            }
            HStack {
                TextField("Add a comment", text: $newComment, axis: .vertical)
                Button {
                    let body = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { return }
                    Task {
                        if let comment = await store.addComment(tx.id, body: body) {
                            comments.append(comment)
                            newComment = ""
                        }
                    }
                } label: { Image(systemName: "paperplane.fill") }
                .disabled(newComment.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var groupedReactions: [(emoji: String, members: [String])] {
        Dictionary(grouping: reactions, by: \.emoji)
            .map { emoji, list in (emoji, list.map { memberName($0.memberID) }) }
            .sorted { $0.emoji < $1.emoji }
    }

    private func memberName(_ id: UUID) -> String {
        if let member = env.session.members.first(where: { $0.id == id }) { return member.displayName }
        return id == env.session.member?.id ? "You" : "Partner"
    }
}
