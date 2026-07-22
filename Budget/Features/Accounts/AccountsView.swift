import SwiftUI
import Charts
import BudgetModels

/// Accounts grouped by type with a net-worth header. Owners can flip an
/// account between shared and private (the Honeydue model) or hide it.
struct AccountsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var linkToken: String?
    @State private var showLink = false

    private var store: AccountStore { env.accountStore }
    private var myMemberID: UUID? { env.session.member?.id }

    var body: some View {
        Group {
            if store.accounts.isEmpty {
                emptyState
            } else {
                List {
                    Section { NetWorthCard(netWorth: store.netWorth) }
                    accountSections
                }
            }
        }
        .navigationTitle("Accounts")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { linkMenu } }
        .task { if store.accounts.isEmpty { await store.load() } }
        .refreshable { await store.load() }
        .overlay { if store.isLinking { ProgressView("Connecting…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
        .fullScreenCover(isPresented: $showLink) {
            if let linkToken {
                PlaidLinkPresenter(
                    linkToken: linkToken,
                    onSuccess: { publicToken in
                        showLink = false
                        Task { await store.exchange(publicToken: publicToken, institutionName: nil) }
                    },
                    onExit: { showLink = false })
                .ignoresSafeArea()
            }
        }
    }

    private var linkMenu: some View {
        Menu {
            Button { connectBank() } label: { Label("Connect a bank", systemImage: "link") }
            #if DEBUG
            Button { Task { await store.linkSandbox() } } label: {
                Label("Link sandbox account (dev)", systemImage: "ladybug")
            }
            #endif
        } label: {
            Image(systemName: "plus")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No accounts yet", systemImage: "building.columns")
        } description: {
            Text("Connect a bank to see balances and net worth.")
        } actions: {
            Button("Connect a bank", action: connectBank)
                .buttonStyle(.borderedProminent)
            #if DEBUG
            Button("Link sandbox account (dev)") { Task { await store.linkSandbox() } }
                .font(.footnote)
            #endif
        }
    }

    @ViewBuilder private var accountSections: some View {
        let visible = store.accounts.filter { !$0.isHidden }
        let groups = Dictionary(grouping: visible, by: \.type)
        ForEach(groups.keys.sorted { $0.sortOrder < $1.sortOrder }, id: \.self) { type in
            Section(type.groupTitle) {
                ForEach(groups[type] ?? []) { account in
                    AccountRow(account: account,
                               canEdit: account.ownerMemberID == myMemberID,
                               onToggleVisibility: { toggleVisibility(account) },
                               onToggleHidden: { Task { await store.update(account, isHidden: !account.isHidden) } })
                }
            }
        }
        let hidden = store.accounts.filter(\.isHidden)
        if !hidden.isEmpty {
            Section("Hidden") {
                ForEach(hidden) { account in
                    AccountRow(account: account,
                               canEdit: account.ownerMemberID == myMemberID,
                               onToggleVisibility: { toggleVisibility(account) },
                               onToggleHidden: { Task { await store.update(account, isHidden: false) } })
                }
            }
        }
    }

    private func connectBank() {
        Task {
            if let token = await store.fetchLinkToken() {
                linkToken = token
                showLink = true
            }
        }
    }

    private func toggleVisibility(_ account: Account) {
        Task { await store.update(account, visibility: account.visibility == .shared ? .private : .shared) }
    }
}

// MARK: - Net worth card

private struct NetWorthCard: View {
    let netWorth: NetWorthResponse?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Net worth").font(.subheadline).foregroundStyle(.secondary)
            Text(currency(netWorth?.current.net ?? 0))
                .font(.system(.largeTitle, design: .rounded).bold())
                .contentTransition(.numericText())
            HStack(spacing: 16) {
                Label(currency(netWorth?.current.assets ?? 0), systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.green)
                Label(currency(netWorth?.current.liabilities ?? 0), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.red)
            }
            .font(.footnote)

            if let series = netWorth?.series, series.count >= 2 {
                Chart(series) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Net", nsDecimal(point.net)))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.tint)
                    AreaMark(x: .value("Date", point.date), y: .value("Net", nsDecimal(point.net)))
                        .foregroundStyle(.tint.opacity(0.12))
                        .interpolationMethod(.monotone)
                }
                .frame(height: 120)
                .chartXAxis(.hidden)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private func nsDecimal(_ d: Money) -> Double { (d as NSDecimalNumber).doubleValue }
}

// MARK: - Account row

private struct AccountRow: View {
    let account: Account
    let canEdit: Bool
    let onToggleVisibility: () -> Void
    let onToggleHidden: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.type.sfSymbol)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(account.name)
                    if account.visibility == .private {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let institution = account.institutionName {
                    Text(account.mask.map { "\(institution) ••\($0)" } ?? institution)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(currency(account.currentBalance, code: account.currencyCode))
                .font(.callout.monospacedDigit())
                .foregroundStyle(account.type.isLiability ? .red : .primary)
        }
        .contextMenu {
            if canEdit {
                Button { onToggleVisibility() } label: {
                    account.visibility == .shared
                        ? Label("Make private", systemImage: "lock")
                        : Label("Make shared", systemImage: "person.2")
                }
                Button { onToggleHidden() } label: {
                    account.isHidden
                        ? Label("Unhide", systemImage: "eye")
                        : Label("Hide", systemImage: "eye.slash")
                }
            }
        }
    }
}

// MARK: - Formatting & type presentation

func currency(_ amount: Money, code: String = "USD") -> String {
    amount.formatted(.currency(code: code))
}

extension AccountType {
    var sfSymbol: String {
        switch self {
        case .checking: return "banknote"
        case .savings: return "dollarsign.circle"
        case .creditCard: return "creditcard"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .loan: return "building.columns"
        case .cash: return "wallet.bifold"
        case .other: return "square.stack"
        }
    }

    var groupTitle: String {
        switch self {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit Cards"
        case .investment: return "Investments"
        case .loan: return "Loans"
        case .cash: return "Cash"
        case .other: return "Other"
        }
    }

    var sortOrder: Int {
        switch self {
        case .checking: return 0
        case .savings: return 1
        case .cash: return 2
        case .investment: return 3
        case .creditCard: return 4
        case .loan: return 5
        case .other: return 6
        }
    }
}
