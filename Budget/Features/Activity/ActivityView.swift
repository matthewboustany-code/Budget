import SwiftUI
import BudgetModels

/// What your partner has been up to: their comments and reactions on the
/// transactions you can see, newest first. Reached from the dashboard bell.
struct ActivityView: View {
    @Environment(AppEnvironment.self) private var env

    private var store: ActivityStore { env.activityStore }

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            if store.events.isEmpty && !store.isLoading {
                ContentUnavailableView("No activity yet",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Comments and reactions your partner leaves on transactions show up here."))
            }
            ForEach(store.events) { event in
                NavigationLink {
                    TransactionLoaderView(transactionID: event.transactionID,
                                          title: event.transactionName)
                } label: {
                    ActivityRow(event: event, isUnread: store.isUnread(event))
                }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task {
            if store.isStale() { await store.load() }
            // Mark read on the way out, not on arrival: clearing the badge
            // before the rows have rendered loses the "these are new" styling
            // the user came here to see.
        }
        .onDisappear { store.markSeen() }
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent
    let isUnread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isUnread ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(event.memberName).font(.subheadline.weight(.semibold))
                    Text(event.kind == .comment ? "commented" : "reacted")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(event.createdAt, format: .relative(presentation: .numeric))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Text(event.summary)
                    .font(.callout)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(event.transactionName).lineLimit(1)
                    Text(event.transactionAmount, format: .currency(code: "USD"))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Pushes straight to a transaction the feed only knows the id of. The feed is
/// denormalized (name + amount only), so the full row is fetched here rather
/// than fattening every event with a whole transaction.
struct TransactionLoaderView: View {
    @Environment(AppEnvironment.self) private var env
    let transactionID: UUID
    let title: String

    @State private var transaction: Transaction?
    @State private var failed = false

    var body: some View {
        Group {
            if let transaction {
                TransactionDetailView(transaction: transaction)
            } else if failed {
                ContentUnavailableView("Transaction unavailable", systemImage: "questionmark.folder",
                                       description: Text("It may have been deleted."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            guard transaction == nil else { return }
            if let detail = await env.transactionStore.detail(transactionID) {
                transaction = detail.transaction
            } else {
                failed = true
            }
        }
    }
}
