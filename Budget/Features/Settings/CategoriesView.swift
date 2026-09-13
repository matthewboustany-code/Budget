import SwiftUI
import BudgetModels

/// Settings › Categories: create, rename, pick an icon, archive / restore, and
/// reorder (Edit, then drag) the household's categories, plus the merchant
/// rules created from the transaction detail's "Apply to all" prompt.
struct CategoriesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editing: EditTarget?

    private var store: CategoryStore { env.categoryStore }

    /// New category in a group, or an existing one.
    enum EditTarget: Identifiable {
        case new(groupID: UUID)
        case existing(BudgetCategory)
        var id: String {
            switch self {
            case .new(let groupID): "new-\(groupID)"
            case .existing(let category): category.id.uuidString
            }
        }
    }

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            ForEach(store.groups) { group in
                Section(group.name) {
                    ForEach(store.categories.filter { $0.groupID == group.id }) { category in
                        Button { editing = .existing(category) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: category.icon ?? "tag")
                                    .foregroundStyle(CategoryPalette.color(for: category))
                                    .frame(width: 24)
                                Text(category.name)
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions(edge: .trailing) {
                            Button("Archive", systemImage: "archivebox") {
                                Task { await store.archive(category.id) }
                            }
                            .tint(.orange)
                        }
                    }
                    .onMove { source, destination in
                        Task { await store.move(in: group.id, from: source, to: destination) }
                    }
                    Button { editing = .new(groupID: group.id) } label: {
                        Label("Add category", systemImage: "plus")
                    }
                }
            }

            if !store.archived.isEmpty {
                Section {
                    ForEach(store.archived) { category in
                        Label(category.name, systemImage: category.icon ?? "tag")
                            .foregroundStyle(.secondary)
                            .swipeActions(edge: .trailing) {
                                Button("Restore", systemImage: "arrow.uturn.backward") {
                                    Task { await store.restore(category.id) }
                                }
                                .tint(.green)
                            }
                    }
                } header: {
                    Text("Archived")
                } footer: {
                    Text("Archived categories keep their history. Swipe to restore.")
                }
            }

            Section {
                NavigationLink { CategoryRulesView() } label: {
                    Label("Merchant rules", systemImage: "wand.and.stars")
                }
            }
        }
        .navigationTitle("Categories")
        .toolbar { EditButton() }
        .sheet(item: $editing) { target in
            NavigationStack { CategoryEditorSheet(target: target) }
        }
        .task { await store.load() }
    }
}

/// Name + icon for a new or existing category.
private struct CategoryEditorSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let target: CategoriesView.EditTarget

    @State private var name: String
    @State private var icon: String
    /// nil means "no color chosen" — the category keeps the deterministic
    /// fallback rather than being pinned to whatever swatch happened to be
    /// first in the grid.
    @State private var colorHex: String?

    static let icons = [
        "tag", "cart", "house", "car", "fork.knife", "cup.and.saucer", "bag", "tshirt",
        "film", "music.note", "gamecontroller", "book", "graduationcap", "airplane",
        "heart", "cross.case", "figure.run", "pawprint", "gift", "leaf",
        "bolt", "drop", "wifi", "phone", "wrench.and.screwdriver", "scissors",
        "dollarsign.circle", "creditcard", "banknote", "building.columns",
    ]

    init(target: CategoriesView.EditTarget) {
        self.target = target
        if case .existing(let category) = target {
            _name = State(initialValue: category.name)
            _icon = State(initialValue: category.icon ?? "tag")
            _colorHex = State(initialValue: category.colorHex)
        } else {
            _name = State(initialValue: "")
            _icon = State(initialValue: "tag")
            _colorHex = State(initialValue: nil)
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section { TextField("Name", text: $name) }
            colorSection
            Section("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(Self.icons, id: \.self) { symbol in
                        Button { icon = symbol } label: {
                            Image(systemName: symbol)
                                .font(.title3)
                                .foregroundStyle(previewColor)
                                .frame(width: 40, height: 40)
                                .background(icon == symbol ? Color.accentColor.opacity(0.2) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(isNew ? "New category" : "Edit category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { if await save() { dismiss() } } }
                    .disabled(trimmed.isEmpty)
            }
        }
    }

    private var isNew: Bool { if case .new = target { true } else { false } }

    /// What the icon and the chosen swatch are drawn in right now — the saved
    /// color if there is one, otherwise the fallback this category will
    /// actually get, so the preview never lies about the unset state.
    private var previewColor: Color {
        if let colorHex, let color = Color(hex: colorHex) { return color }
        if case .existing(let category) = target { return CategoryPalette.color(for: category) }
        return .accentColor
    }

    @ViewBuilder
    private var colorSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(CategoryPalette.swatches, id: \.self) { hex in
                    Button {
                        // Tapping the chosen swatch again clears it, which is
                        // the only way back to the automatic color.
                        colorHex = (colorHex == hex) ? nil : hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 30, height: 30)
                            .overlay {
                                if colorHex == hex {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hex)
                    .accessibilityAddTraits(colorHex == hex ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Color")
        } footer: {
            Text(colorHex == nil
                 ? "Automatic — a stable color picked from the category. Tap a swatch to choose your own."
                 : "Tap the selected color again to go back to automatic.")
        }
    }

    private func save() async -> Bool {
        switch target {
        case .new(let groupID):
            await env.categoryStore.create(groupID: groupID, name: trimmed,
                                           icon: icon, colorHex: colorHex)
        case .existing(let category):
            // "" is the wire's explicit "back to automatic"; nil would read as
            // "don't touch the color" and silently keep the old one.
            await env.categoryStore.update(category.id,
                                           .init(name: trimmed, icon: icon, colorHex: colorHex ?? ""))
        }
    }
}

/// The household's "always file this merchant here" rules; swipe to delete.
private struct CategoryRulesView: View {
    @Environment(AppEnvironment.self) private var env
    private var store: CategoryStore { env.categoryStore }

    var body: some View {
        Group {
            if store.rules.isEmpty {
                ContentUnavailableView("No rules yet", systemImage: "wand.and.stars",
                    description: Text("Change a transaction's category and choose “Apply to all” to create one."))
            } else {
                List {
                    Section {
                        ForEach(store.rules) { rule in
                            // HStack, not LabeledContent: with a Label as its content,
                            // LabeledContent in a List row on iOS 26 stretched the
                            // section to fill the screen (same bug as 1.14's Menu).
                            HStack {
                                Text(rule.merchantKey.capitalized)
                                Spacer()
                                Label(store.name(for: rule.categoryID), systemImage: store.icon(for: rule.categoryID))
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task { await store.deleteRule(rule) }
                                }
                            }
                        }
                    } footer: {
                        Text("Deleting a rule stops future matches; transactions it already filed keep their category.")
                    }
                }
            }
        }
        .navigationTitle("Merchant rules")
        .task { await store.loadRules() }
    }
}
