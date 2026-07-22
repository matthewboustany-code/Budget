# Budget

A personal budgeting app for a couple, blending the best of **Honeydue**
(shared household with per-account privacy, transaction chat + reactions),
**Monarch Money** (connected accounts, net worth, cash flow, flexible monthly
category budgets), and **YNAB** (disciplined category budgeting with rollover).

**Native iOS (SwiftUI) + Swift/Vapor backend + a shared Swift package**, sized
for self-hosting for you and your partner. Real bank data via **Plaid**; sign-in
via **Sign in with Apple**.

> Conventions deliberately mirror the sibling `FlightBag` project: a SwiftUI app
> + Vapor server + a Linux-clean shared SPM package, GRDB for SQLite, ISO8601
> JSON, `Environment.get` + `.env` for secrets, and Swift Testing.

## Repository layout

```
Budget/
├── Budget.xcodeproj          # iOS app (Xcode 26, file-system-synchronized groups)
├── Budget/                   # App sources (auto-included by the sync group)
│   ├── App/                  # BudgetApp, RootTabView, AppEnvironment, Session
│   ├── Features/             # One folder per feature screen
│   └── Services/             # APIClient, Keychain, ServerConfig
├── Packages/BudgetCore/      # SHARED package (app + server), zero external deps
│   └── Sources/
│       ├── BudgetModels/     # Codable domain types + API DTOs
│       └── BudgetKit/        # Pure budget/net-worth/recurring math
├── Server/                   # Vapor 4 backend (GRDB/SQLite, auth, Plaid)
│   └── Sources/App/{Auth,Database,Plaid,Services,Commands,Routes}
├── docs/                     # architecture.md, code-map.md
└── scripts/                  # cron / ops scripts
```

The **shared package is the key design point**: `BudgetModels` and `BudgetKit`
are compiled into both the app and the server, so the two can never disagree
about a data shape or a budget calculation.

## Build, run, test

### Shared package (`BudgetCore`)
```bash
cd Packages/BudgetCore
swift test          # models + calculation engine (offline, no deps)
```

### Server (`Vapor`)
```bash
cd Server
cp .env.example .env          # then fill in secrets (see below)
swift run App serve --hostname 127.0.0.1 --port 8080
# health check:
curl http://127.0.0.1:8080/v1/health
```
First build fetches Vapor, GRDB, and JWT from GitHub (~2–3 min).

### iOS app
Open `Budget.xcodeproj` in Xcode and run on an iOS 26 simulator, or:
```bash
xcodebuild -project Budget.xcodeproj -scheme Budget \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```
The app defaults to `http://localhost:8080` (the simulator shares the host
network). Override for a run with the `-serverBaseURL <url>` launch argument.

> **Keychain needs a signed build.** Running from Xcode signs automatically. For
> CLI builds, sign (even ad-hoc) so the app gets an `application-identifier` —
> otherwise Keychain writes fail and the session token won't persist. Use
> `CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES` (not `CODE_SIGNING_ALLOWED=NO`).

### Dev auth (no Apple account needed yet)
The server's `AUTH_DEV_MODE` (on by default outside production) accepts a dev
token so the whole auth + household flow works without an Apple Developer
account. In DEBUG the app shows "Sign in as Alice / Bob" buttons, and supports
scripted launch args: `-resetSession`, `-autoDevSignIn <name>`, `-startTab <id>`.

## Configuration & secrets

All secrets live in `Server/.env` (git-ignored); `Server/.env.example` is the
template. Nothing sensitive is stored on the device — Plaid access tokens stay
server-side (encrypted at rest), and the app keeps only its session bearer token
in the Keychain.

You will need to supply, when those phases land:
- **Apple Developer Program** — an App ID with *Sign in with Apple*, a Services
  ID, and a sign-in key (Phase 1).
- **Plaid** account — `client_id` + `sandbox` secret to start; Production needs
  Plaid approval (Phase 2).

## Status

Built in incremental, independently-runnable phases (see
`docs/architecture.md`).

- ✅ **P0 — Scaffolding.** Shared package with tested models + calculation
  engine; Vapor server skeleton with GRDB migrations and a `/v1/health` probe;
  iOS app shell (tab navigation, DI container, API client, Keychain) that
  confirms app↔server↔database connectivity.
- ✅ **P1 — Auth & households.** Sign in with Apple (Apple identity-token
  verification + our own session JWTs, with a dev-auth mode for testing);
  create/join a household via single-use invite codes; per-household membership.
  Onboarding + Settings UI. 5 server tests cover the full couples flow.
- ✅ **P2 — Plaid, accounts & net worth.** Plaid client (link-token, exchange,
  accounts/balance, sandbox) with access tokens AES-GCM encrypted at rest;
  account/balance sync; Accounts screen grouped by type with net worth and
  per-account privacy toggle (owner-only); Plaid LinkKit for real linking plus a
  dev sandbox-link path for testing; nightly balance + net-worth snapshot
  commands. 9 server tests (incl. privacy enforcement); verified live against
  Plaid sandbox (12 real accounts).
- ✅ **P3 — Transactions & couples layer.** Plaid `/transactions/sync` (+ webhook
  and initial pull on link); default category tree seeded per household with
  auto-categorization from Plaid's categories; transactions list (grouped by day,
  search, pagination) and detail (recategorize, note, review, privacy); Honeydue
  comments + emoji reactions. 13 server tests; verified live (50 sandbox
  transactions auto-categorized).
- ⬜ P4 — Monarch-style monthly budgets
- ⬜ P5 — Bills/recurring + goals
- ⬜ P6 — Dashboard & reports
- ⬜ P7 — Hardening, TLS, Docker deploy
