# Code map

Where everything lives and what it does — one line per file, grouped the way
the repo is. Companion to `architecture.md` (the *why*); this is the *where*.

## Packages/BudgetCore — shared package (app + server)

Zero external dependencies, Linux-clean. The wire contract and the math live
here so the app and server can never disagree.

### Sources/BudgetModels — Codable domain types + API DTOs

| File | Contents |
|---|---|
| `Primitives.swift` | `Money` (= `Decimal`), `Visibility`, `AccountType`, `TransactionStatus`, `BillStatus`, `RecurringCadence`, `MemberRole`, and the `Month` value type (encoded `"YYYY-MM"`). |
| `Household.swift` | `User`, `Household`, `HouseholdMember`, `InviteCode`. |
| `Account.swift` | `Account` (balances, institution, per-account `visibility`, `isHidden`). |
| `Transaction.swift` | `Transaction` (amount sign: positive = outflow), `TransactionSplit`, `TransactionComment`, `TransactionReaction`. |
| `Budgeting.swift` | `CategoryGroup`, `BudgetCategory`, monthly `Budget` (+ rollover flag), `BudgetProgress`, `MonthBudget`. |
| `BillsGoals.swift` | `RecurringSeries`, `Bill` (a projected occurrence), `Goal`, `GoalContribution`. |
| `Reporting.swift` | `NetWorthPoint`, `CashFlowSummary`, `SpendingByCategory`. |
| `APIDTOs.swift` | Every request/response envelope, phase by phase — auth, household, Plaid, transactions, budgets, recurring/bills, goals, reports, `APIErrorResponse`. |

### Sources/BudgetKit — pure calculation engine

| File | Contents |
|---|---|
| `BudgetCalculations.swift` | `BudgetCalculator` — spent-per-category (split-aware), budget-vs-actual with the rollover walk, `monthBudget` rollup. |
| `Reports.swift` | `ReportCalculator` — cash flow, spending-by-category, net worth (+ snapshot series sort). |
| `RecurringDetector.swift` | Heuristic recurring detection: normalized merchant key, median-gap cadence, amount-stability and mixed-sign (charge/refund) rejection. |
| `BillProjector.swift` | Projects active series into dated `Bill` occurrences (calendar-aware stepping, overdue marking). Never stored — recomputed per read. |
| `Month+Calendar.swift` | `Month` ↔ `Date` bridging (`init(date:)`, `startDate`, ranges). |

### Tests

`BudgetKitTests` (calculations, reports, detection, projection — the
highest-value pure-logic tests) and `BudgetModelsTests` (codable round-trips,
computed properties).

## Server — Vapor 4 backend

| File | Contents |
|---|---|
| `entrypoint.swift` / `configure.swift` / `routes.swift` | Standard Vapor trio: boot, app assembly (JSON coding, config load, JWT key, DB, commands), route registration. |
| `AppConfig.swift` | Env-loaded config; **production fail-fast** (`validate`) refuses placeholder secrets and `AUTH_DEV_MODE`. |
| `ContentConformances.swift` | Retroactive `Content` conformances for the shared DTOs (keeps `BudgetCore` Vapor-free). |
| `Extensions.swift` | Small shared helpers (`String.nilIfEmpty`). |

### Auth/

| File | Contents |
|---|---|
| `AppleTokenVerifier.swift` | Verifies Apple identity tokens against Apple's JWKS; dev-token path behind `authDevMode`. |
| `SessionToken.swift` | Our HMAC-signed session JWT (60-day expiry). |
| `AuthMiddleware.swift` | Bearer verification → `req.authenticatedUser`; `requireUser()`. |

`requireMembership()` (user → household + member, or 403) lives in
`Services/AccountSyncService.swift` as a `Request` extension.

### Database/ — GRDB stores (SQL in, shared DTOs out)

| File | Contents |
|---|---|
| `AppDatabase.swift` | `DatabasePool` (WAL) + migrator hookup; injected before `configure` in tests. |
| `Migrations.swift` | Versioned schema, one `v1_core_schema` migration; money as TEXT decimals, dates as ISO8601 TEXT. |
| `DBFormat.swift` / `RowMapping.swift` | TEXT ↔ Swift conversions; `Row` → DTO initializers. |
| `UserStore` / `HouseholdStore` | Users, households, memberships, invite codes. |
| `AccountStore` | Accounts incl. visibility-scoped listing; net-worth inputs. |
| `TransactionStore` | Visibility-join listing/pagination/search, PATCH updates, `upsertPlaid` (preserves user edits). |
| `CategoryStore` | Category tree CRUD (delete = archive) + `CategorySeeder` (default tree, Plaid category mapping) + transfer-category lookup. |
| `CategoryRuleStore` | Merchant → category rules keyed by `RecurringDetector.normalize`; `apply` upserts a rule and recategorizes visible matches whose `category_source` isn't `user`. |
| `MerchantKeyMigration` | v11 re-keying of `recurring_series` / `category_rules` after `RecurringDetector.normalize` changed; recovers rule merchants via `legacyNormalize`. |
| `BudgetStore` | Monthly budget upsert/list (storage only — math is BudgetKit's). |
| `CommentReactionStore` | Honeydue comments + reactions, plus `feed` — the partner activity feed (one UNION over both tables, same visibility join as `TransactionStore.list`, the caller's own events excluded). |
| `RecurringStore` | Series listing (account-visibility scoped), PATCH, `mergeDetected` (detection owns numbers; user owns name/category/off-switch). |
| `GoalStore` | Goals CRUD + contribution ledger (running total recomputed in the same write transaction). |
| `NetWorthStore` / `PlaidItemStore` | Daily snapshots; encrypted Plaid items + sync cursors. |

### Plaid/

| File | Contents |
|---|---|
| `PlaidClient.swift` | Typed Plaid API client over the injectable `PlaidTransport` (tests use canned fixtures). |
| `PlaidModels.swift` | Plaid request/response shapes (snake_case coded). |
| `TokenCipher.swift` | AES-GCM encryption for access tokens at rest. |
| `PlaidWebhookVerifier.swift` | `Plaid-Verification` ES256 JWT verification (per-`kid` JWK fetch, freshness, exact body SHA-256). |

### Services/ & Commands/

| File | Contents |
|---|---|
| `AccountSyncService.swift` | Link/exchange → account import; balance refresh. |
| `TransactionSyncService.swift` | `/transactions/sync` cursor loop → upsert/categorize (household rule first, then Plaid's category) → triggers recurring re-detection. |
| `RecurringService.swift` | Runs `RecurringDetector` over shared-visibility history, merges into storage. |
| `PushService.swift` | APNs setup (sandbox + production containers from one key) and sends; prunes dead tokens. `notifyComment` is the activity feed's push half — best-effort, visibility-checked, threaded by transaction id. |
| `SyncCommands.swift` | `sync-all` (nightly refresh, ends with a net-worth snapshot) + `networth-snapshot`. |
| `BillReminderCommand.swift` | `bill-reminder` — logs overdue/due-soon bills per household and pushes one digest per household when APNs is configured. |

### Routes/ — one file per feature under `/v1`

`Auth`, `Household`, `Plaid` (link/exchange/sandbox/webhook), `Account`
(+ `/networth`), `Category`, `CategoryRule` (list/preview/create/delete), `Transaction` (+ comments/reactions, review-summary), `Budget`,
`Recurring` (+ `/bills/upcoming`), `Goal`, `Report` (cashflow/spending),
`Activity` (`GET /v1/activity?since=&limit=` — the partner feed), `Device`,
`Health`. Every data route resolves membership and enforces per-item
visibility; cross-household access reads as 404.

### Tests/AppTests — Swift Testing + VaporTesting, per-test SQLite files

`AuthHouseholdTests`, `PlaidSyncTests` (incl. the `MockPlaidTransport`
fixtures), `BudgetTests`, `BillsGoalsTests`, `ReportsTests`,
`HardeningTests` (config fail-fast, webhook signature verification),
`ActivityFeedTests` (partner-only filtering, private-account chatter, `since=`).

### Deployment (Server/)

`Dockerfile` (multi-stage, repo-root context), `docker-compose.yml` (API +
Caddy auto-TLS), `Caddyfile`, `scripts/sync-cron.sh`, `scripts/backup-db.sh`,
`DEPLOY.md`.

## Budget/ — the iOS app

### App/

| File | Contents |
|---|---|
| `BudgetApp.swift` | Entry point; injects `AppEnvironment`; onboarding vs. main gate. |
| `AppEnvironment.swift` | `@MainActor @Observable` DI container holding every store; launch bootstrap. |
| `Session.swift` | Auth state + Keychain-backed token. |
| `RootTabView.swift` | Home / Accounts / Transactions / Budget / Settings tabs (`.sidebarAdaptable`); selection lives in `AppEnvironment.selectedTab` so one tab can open another. |
| `TypeAliases.swift` | `Transaction`/`Budget` disambiguation (SwiftUI and the module name collide). |

### Services/

| File | Contents |
|---|---|
| `APIClient.swift` | The single bearer-authenticated HTTP client (ISO8601, typed errors); central 401 → sign-out. |
| `ResponseCache.swift` | Last-good JSON per GET in Application Support; stores prefill from it at init. Cleared on sign-out. |
| `Staleness.swift` | `StaleAware.isStale(after:)` (5 min) over each store's `lastLoaded`; screens refresh on `.task` when stale, and `AppEnvironment.refreshStale()` on foreground. |
| `Keychain.swift` / `ServerConfig.swift` / `LaunchArgs.swift` | Token storage; base-URL resolution; DEBUG scripted-launch flags. |
| `AuthStore` / `HouseholdStore` | Sign in with Apple (+ dev sign-in), household create/join/invite. |
| `AccountStore` | Accounts + net worth; Plaid link-token/exchange/sandbox. |
| `TransactionStore` / `CategoryStore` / `BudgetStore` | Feature state mirroring the corresponding endpoints. `CategoryStore` loads archived rows too (`archived`, and names for old transactions) and owns category management + merchant rules. |
| `BillsStore` / `GoalsStore` / `ReportsStore` | P5/P6 state: series + projected bills, goals + contributions, cashflow/spending. |
| `ActivityStore` | Partner feed + the bell's unread count. "Unread" is a per-device last-seen timestamp in `UserDefaults`, never server state. |
| `PlaidLinkPresenter.swift` | Wraps Plaid LinkKit. |

### Features/ — one folder per screen

`Onboarding` (sign-in → create/join household), `Dashboard` (Monarch-style
home: activity bell, "N to review" row, net-worth sparkline, cash flow, budget bar,
due-soon bills),
`Accounts` (incl. "Needs attention" reconnect and `ManualEntrySheets.swift` for
manual accounts/transactions), `Transactions` (list with filter sheet — review /
uncategorized / account / category / dates — plus detail with comments/reactions,
and `SplitEditorView.swift` for splitting one transaction across categories),
`Budget` (month switcher, budget-vs-actual, set-budget sheet),
`Bills` (Upcoming/Recurring segments, series toggles), `Goals` (progress
list, detail + contribution ledger, create/edit sheets),
`Reports` (Swift Charts: cashflow bars, spending bars, net-worth line),
`Settings` (members, invite, connection status, sign out; `CategoriesView.swift`
for category create/rename/icon/archive/restore/reorder and merchant rules),
`Activity` (`ActivityView` — the partner feed behind the dashboard bell, plus
`TransactionLoaderView`, which fetches a transaction the feed knows only by id),
`Shared/PlaceholderScreen` (onboarding placeholder).
