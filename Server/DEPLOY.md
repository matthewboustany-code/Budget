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
| `APPLE_BUNDLE_ID` | the app's bundle id (`com.mbandhb.budget`) |
| `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_KEY_P8` / `APNS_ENV` | optional — bill-reminder push. Leave blank to keep reminders log-only |
| `BUDGET_DOMAIN` | your DNS name |
| `BUDGET_DATA_DIR` | where the database should live on the host (default `./data`) |

`BUDGET_DATA_DIR` is bind-mounted into the container, and the image runs as its
unprivileged `vapor` user (**uid 999**) — not as the user doing the deploy. A
directory Docker creates for the bind mount is owned by that deploying user, so
the server dies on boot with `SQLite error 14: unable to open database file`.
Create it and hand it over first:

```bash
mkdir -p "${BUDGET_DATA_DIR:-./data}"
sudo chown -R 999:999 "${BUDGET_DATA_DIR:-./data}"
```

Then:

```bash
docker compose up -d --build
curl https://<BUDGET_DOMAIN>/v1/health   # {"status":"ok","database":true,...}
```

The image builds from the repo root so the `../Packages/BudgetCore` path
dependency resolves — compose sets that context for you.

**Production refuses placeholder secrets.** If the server exits immediately,
`docker compose logs server` will name the variable it rejected — one
`Configuration error:` line, exit code **78** (`EX_CONFIG`). Compose will keep
restarting it, so a config mistake shows up as a steady loop of that one line.

## Point the app at it

In the iOS app, open **Settings → Backend → Server** and enter the address.
Set it to `https://<BUDGET_DOMAIN>`. Changing it signs you out, because the
session token was minted by the previous server. (Under the hood this is
`ServerConfig`, UserDefaults key `serverBaseURL`; DEBUG builds can also be
pointed with the `-serverBaseURL` launch argument.) The built-in default is
`http://localhost:8080`, which only resolves in the Simulator — a real device
must be given a reachable address here. Real Sign in with Apple requires the app built with
the entitlement and your Apple team; each partner signs in and joins the
household with an invite code from Settings.

## LAN testing without a domain

For user testing on a device with no public DNS name, use the alternate stack:

```bash
docker compose -f docker-compose.lan.yml up -d --build
curl http://<host-lan-ip>:8081/v1/health
```

It publishes the API directly and runs no Caddy, because Let's Encrypt cannot
issue a certificate for a private address and iOS would reject a self-signed
one. The app's `NSAllowsLocalNetworking` exception (`Config/Info.plist`) permits
cleartext HTTP to private addresses only, so `http://192.168.x.x:8081` works
while arbitrary internet HTTP stays blocked. Set `BUDGET_LAN_PORT` if 8081 is
taken. It stores data in a named volume, so it needs none of the `chown` above.

This stack has **no TLS** — keep it on the LAN, never port-forward it.

## Going from Plaid sandbox to production

The config change is small; the OAuth requirement is the part that bites.

1. **Apply for production access** in the Plaid dashboard. Expect to supply
   company details, the use case, expected volume, a security questionnaire,
   and **publicly reachable Privacy Policy and Terms of Service URLs**.
   Production is billed per Item per month.
2. **Swap the credentials**: `PLAID_ENV=production` and the production
   `PLAID_SECRET`. The client id does not change.
3. **Re-link every account.** Sandbox access tokens are void in production, so
   existing `plaid_items` rows are dead and each institution must be linked
   again through the real Link flow.
4. **Set `PLAID_REDIRECT_URI`** and register the identical URI in the Plaid
   dashboard for Production. Without it, OAuth institutions — most large US
   banks — fail while small ones succeed. The server logs a warning on every
   link-token request if it is unset in production.

The iOS side of OAuth is already wired up:

- `Budget.entitlements` declares `applinks:mbandhb.com`.
- The website's Caddy serves
  `https://mbandhb.com/.well-known/apple-app-site-association` as
  `application/json` with no redirect, mapping `/plaid-oauth*` to
  `38S88ZF435.com.mbandhb.budget`, plus a fallback page at `/plaid-oauth` for
  anyone opening the link without the app installed.
- It is served from the Caddyfile rather than the site's `/srv` directory on
  purpose: `/srv` is an Astro build checked out from git, so a file placed there
  would be deleted by the next site deploy — and a universal link that vanishes
  during an unrelated deploy is a nasty failure to trace.
- Verify Apple can see it with:
  `curl https://app-site-association.cdn-apple.com/a/v1/mbandhb.com`

LinkKit 7.x handles the OAuth return itself once the universal link resolves —
there is no `receivedRedirectUri` to pass and no URL handling needed in the app.

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
  `AUTH_DEV_MODE`. The image sets `VAPOR_ENV=production`, so the scheduled
  one-off commands get the same validation as `serve` rather than silently
  running in development (pass `--env development` to override locally).
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
