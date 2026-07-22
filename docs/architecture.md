# Architecture

The *why* behind Budget's structure, and the decisions that are locked. Reads
like FlightBag's `docs/architecture.md`.

## Shape

Three components, one shared core:

1. **`Packages/BudgetCore`** — a Linux-clean, zero-dependency SPM package
   compiled into **both** the app and the server.
   - `BudgetModels` — every Codable domain type and API DTO. No UIKit/SwiftUI,
     no GRDB, no Vapor. This is the contract on the wire.
   - `BudgetKit` — pure functions for budget-vs-actual, net worth, cash flow,
     spending-by-category, and recurring detection. The app uses them for
     instant local rollups; the server uses them for authoritative report
     endpoints. One implementation means the two can never disagree — the same
     rationale FlightBag used for its shared `FBFlightPlan`.
2. **`Server/`** — Vapor 4, a live GRDB/SQLite database, Sign in with Apple,
   Plaid ingestion, and scheduled sync commands.
3. **`Budget/`** (app) — SwiftUI, an `@Observable AppEnvironment` DI container
   injected at the root (no singletons, no ViewModels), feature-based folders,
   and a single bearer-authenticated `APIClient`.

## Locked decisions

| Decision | Choice | Why |
|---|---|---|
| Platform | Native iOS 26, SwiftUI | The chosen target; matches the Xcode project. |
| Backend | Swift / Vapor 4 | Matches FlightBag; shares the SPM package with the app. |
| Data source | Plaid (Sandbox → Production) | Real bank sync was the requirement. |
| Budget model | Monarch-style flexible monthly budgets + optional rollover | Simpler and more forgiving than strict zero-based envelopes. |
| Scale / hosting | Personal, self-hosted | You + partner + a few households. |
| Database | SQLite via GRDB (`DatabasePool`, WAL) | Single-file, self-host-friendly; enough concurrency for a couple. |
| Money | `Decimal` everywhere, stored as exact strings | Never trust binary floating point with currency; sum in Swift via BudgetKit. |
| Auth | Sign in with Apple; partner joins by invite code | Native, no passwords to store — a real win for a finance app. |
| Sharing | Shared household with per-account/-transaction visibility | Honeydue's "hide from partner" model. |

## Deliberate divergences from FlightBag

FlightBag is a public, read-only, static-artifact host with no auth and a
DB-as-shipped-artifact. Budget needs the opposite in a few places:

1. **Live, mutable, multi-user DB** → GRDB `DatabaseMigrator` + record structs,
   not FlightBag's raw-SQL, no-migration, rebuilt-each-cycle model.
2. **Auth layer** — Sign in with Apple + our own session JWT + Keychain +
   `vapor/jwt`. FlightBag has none anywhere.
3. **Central `APIClient` with bearer auth** — FlightBag had no auth and split
   networking per concern.
4. **TLS mandatory from day one** (finance data) via a Caddy reverse proxy —
   FlightBag ran plain HTTP on a LAN by design.

## Concurrency

The Xcode project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (approachable
concurrency). App state (`Session`, `AppEnvironment`), the `APIClient`, and the
views are all main-actor; network I/O is `async` and suspends, so it never
blocks the UI. There are no explicit background actors in the app — the source
of truth for shared data is the server, not the device.

## Data model (at a glance)

`User` → `HouseholdMember` → `Household` owns everything else: `Account`s (each
owned by a member, with a `visibility`), `Transaction`s (with per-item
visibility, optional `splits`, `comments`, `reactions`), `CategoryGroup`/
`BudgetCategory`, monthly `Budget`s, `RecurringSeries`/`Bill`s, `Goal`s, and
`NetWorthSnapshot`s. Plaid `access_token`s live only in `plaid_items`, encrypted
at rest.

## Deployment

One Docker host: the Vapor API (no published port) behind Caddy, which owns
80/443 and the Let's Encrypt certificate for `BUDGET_DOMAIN`. The database is
a single SQLite file on a mounted volume; cron runs the nightly Plaid sync and
a WAL-safe `.backup`. Production boot refuses placeholder secrets and dev-auth
mode, and Plaid webhooks must carry a valid `Plaid-Verification` signature.
Details in `Server/DEPLOY.md`; the file-by-file map is `docs/code-map.md`.

## Phases

See the top-level `README.md` for the P0–P7 build order. Each phase is
independently runnable and ends with a green build + tests.
