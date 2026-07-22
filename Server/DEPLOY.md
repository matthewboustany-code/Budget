# Deploying the Budget server

Self-hosted, for one household: a single Docker host (Mac mini, NAS, or small
VPS) runs the Vapor API behind Caddy, which terminates TLS with an automatic
Let's Encrypt certificate. The database is one SQLite file on a mounted volume.

```
iPhone app ──HTTPS──▶ Caddy (:443, auto-TLS) ──▶ server (Vapor, :8080)
                                                    │
                                              /data/budget.sqlite
Plaid ──webhook──▶ (same path; Plaid-Verification JWT checked)
```

## Prerequisites

- A host with **Docker + docker compose** and ports **80/443** reachable from
  the internet (Caddy needs both for the ACME challenge and for serving).
- A **DNS name** (e.g. `budget.example.com`) pointing at the host.
- **Plaid** credentials — sandbox works end-to-end; Production keys require
  Plaid's approval process.
- **Apple Developer Program** membership for real Sign in with Apple (an App ID
  with the capability; the app entitlement). Until then `AUTH_DEV_MODE` covers
  development — but never production (the server refuses to boot with it).

## First deployment

```bash
git clone <this repo> && cd Budget/Server
cp .env.example .env
```

Edit `.env`:

| Variable | Set it to |
|---|---|
| `SESSION_JWT_SECRET` | `openssl rand -hex 32` |
| `PLAID_TOKEN_ENC_KEY` | `openssl rand -hex 32` (rotating it orphans stored Plaid tokens — relink) |
| `PLAID_CLIENT_ID` / `PLAID_SECRET` / `PLAID_ENV` | from the Plaid dashboard |
| `PLAID_WEBHOOK_URL` | `https://<BUDGET_DOMAIN>/v1/plaid/webhook` |
| `APPLE_BUNDLE_ID` | the app's bundle id (`Me.Budget`) |
| `BUDGET_DOMAIN` | your DNS name |
| `BUDGET_DATA_DIR` | where the database should live on the host (default `./data`) |

Then:

```bash
docker compose up -d --build
curl https://<BUDGET_DOMAIN>/v1/health   # {"status":"ok","database":true,...}
```

The image builds from the repo root so the `../Packages/BudgetCore` path
dependency resolves — compose sets that context for you.

**Production refuses placeholder secrets.** If the server exits immediately,
`docker compose logs server` will name the variable it rejected.

## Point the app at it

In the iOS app the server URL comes from `ServerConfig` (UserDefaults key
`serverBaseURL`, or the `-serverBaseURL` launch argument in DEBUG). Set it to
`https://<BUDGET_DOMAIN>`. Real Sign in with Apple requires the app built with
the entitlement and your Apple team; each partner signs in and joins the
household with an invite code from Settings.

## Scheduled jobs (cron on the host)

```cron
30 2 * * *  /path/to/Budget/Server/scripts/sync-cron.sh
0  3 * * *  /path/to/Budget/Server/scripts/backup-db.sh
```

- `sync-cron.sh` — refreshes balances + transactions for every linked Plaid
  item (recurring detection and the daily net-worth snapshot ride along), then
  logs bill reminders. Failures POST to `BUDGET_FAIL_WEBHOOK` if set. The Plaid
  webhook keeps transactions fresh during the day; this is the safety net.
- `backup-db.sh` — WAL-safe `.backup` inside the running container into
  `$BUDGET_DATA_DIR/backups/`, pruned after `BUDGET_BACKUP_KEEP_DAYS` days.
  **Restore:** `docker compose down`, copy the chosen backup over
  `$BUDGET_DATA_DIR/budget.sqlite`, delete any `-wal`/`-shm` sidecars, `up -d`.

## Security posture (what P7 locked in)

- **TLS mandatory** — the API container publishes no host port; Caddy (HSTS,
  auto-renewing certificates) is the only way in.
- **Boot-time secret validation** — production refuses dev-placeholder or
  missing `SESSION_JWT_SECRET` / `PLAID_TOKEN_ENC_KEY`, and refuses
  `AUTH_DEV_MODE`.
- **Plaid webhooks verified** — the `Plaid-Verification` ES256 JWT is checked
  (signature via Plaid's per-`kid` JWK, ≤5-minute freshness, exact body
  SHA-256) before any webhook is acted on.
- **Plaid access tokens** never leave the server and are AES-GCM encrypted at
  rest; the phone holds only its own session JWT (Keychain).
- **Every data route** is household-scoped and honors per-account /
  per-transaction visibility (enforced in SQL joins, covered by tests).
- Non-root container user, 1 MB request cap at the proxy.

## Updating

```bash
git pull
docker compose up -d --build     # GRDB migrations run automatically on boot
```

Take a backup first (`scripts/backup-db.sh`) before an update that changes the
schema. `eraseDatabaseOnSchemaChange` is compiled out of release builds — a
schema change in production is always an additive migration.
