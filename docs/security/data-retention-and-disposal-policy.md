# Data Retention and Disposal Policy — Budget

**Owner:** Matthew Boustany (sole operator)
**Effective date:** 4 September 2026
**Review cadence:** every 6 months, and on any change to what data is collected
**Last reviewed:** 4 September 2026

## Purpose and scope

Budget is a private, self-hosted budgeting app serving a single household. This
policy states how long each category of data is kept, what triggers its
disposal, and how disposal is actually carried out.

It covers all consumer data the app holds, including data retrieved from the
Plaid API, and every place that data comes to rest: the live database, backups,
and operational logs.

Two principles govern everything below:

1. **Keep only what the product needs.** Historical transactions are retained
   because budgets and net-worth trends are meaningless without them. Nothing is
   retained because it "might be useful."
2. **Every store has an expiry.** A store with no stated limit is a store that
   grows forever, and no policy can honestly cover it. Where a limit is claimed
   here, something enforces it automatically.

## What we hold, and for how long

| Data | Retained | Disposal trigger |
|---|---|---|
| Apple account identifier, email, display name | Life of the account | Account deletion |
| Bank account names, types, masks, balances | Life of the account | Account deletion, or disconnecting that institution |
| Transactions (date, amount, description, merchant, category) | Life of the account | Account deletion, or disconnecting that institution |
| Plaid access tokens (encrypted) | Until that institution is disconnected | Disconnection or account deletion |
| Budgets, categories, savings goals, comments, reactions | Life of the household | Deletion of the last member's account |
| Net-worth snapshots | Life of the household | Deletion of the last member's account |
| Push notification device tokens | Until the device deregisters or the token is rejected | Deregistration, APNs reporting the token dead, or account deletion |
| Encrypted database backups | **30 days**, rolling | Automatic pruning |
| Application container logs | **30 MB per service** (3 files × 10 MB), rolling | Automatic rotation |
| Nightly sync run logs | **30 days**, rolling | Automatic pruning |

We do not collect analytics, advertising identifiers, location, or contacts, so
there is nothing in those categories to retain or dispose of.

## Disposal on request

Deletion is available in the app and is **immediate**, not queued or scheduled.

**Disconnecting one institution** (Settings → Connected accounts → Disconnect):
the Item is removed at Plaid first, so the upstream bank connection is severed
and Plaid ceases to hold it; the local record is then deleted, and its accounts
and transactions are removed by database cascade.

**Deleting an account** (Settings → Delete account): every institution the
person owns is removed at Plaid, then their user record is deleted. Memberships,
device tokens, Plaid items, accounts and transactions are removed by cascade. If
they were the last member of the household, the household is deleted, taking
categories, budgets, goals, recurring series, invites and net-worth snapshots
with it. A departing member of a shared household does not remove data belonging
to the partner who remains.

Ordering is deliberate and load-bearing: **Plaid is always told to release the
Item before the local record is destroyed.** The access token lives in that
record, so deleting locally first would leave the Item permanently unreachable —
still connected to the consumer's bank, still held by Plaid. Erasing our copy
while leaving that connection live would not be deletion in any meaningful
sense.

If Plaid cannot be reached, local deletion still proceeds and the failure is
logged for manual follow-up in the Plaid dashboard. A third party's availability
does not delay a consumer's deletion request.

## Disposal method

- **Live database.** Rows are deleted with foreign-key cascades, not flagged as
  inactive. There is no soft delete and no shadow copy; a deleted row is gone
  from the working set at the point of deletion.
- **Backups.** Data already captured in a backup persists until that backup ages
  out, at most 30 days. Backups are removed by automatic pruning. Every backup
  is encrypted (SQLCipher, AES-256), so an expired-but-not-yet-overwritten
  fragment is not readable without the key.
- **Whole-database disposal.** Because the database is encrypted at rest,
  destroying the key renders every copy — live and backup — permanently
  unreadable. This is the disposal method for decommissioning the service.
- **Physical media.** The service runs on a single self-hosted virtual machine.
  Should the underlying hardware be retired, sold, or disposed of, its storage is
  to be securely erased before it leaves the operator's possession.

## Retention limits are enforced, not aspirational

| Limit | Enforced by |
|---|---|
| 30-day backup retention | `Server/scripts/backup-db.sh` (pruning on every run) |
| 30-day sync log retention | `Server/scripts/sync-cron.sh` (pruning on every run) |
| Container log rotation | `logging:` in `Server/docker-compose*.yml` |
| Account and connection deletion | `Server/Sources/App/Services/DeletionService.swift` |
| Plaid Item released before local delete | Same, with test coverage in `Server/Tests/AppTests/DeletionTests.swift` |
| Dead push tokens pruned | `Server/Sources/App/Services/PushService.swift` |

Deletion behavior is covered by automated tests, including that the Item is
released at Plaid, that a departing partner leaves shared data intact, and that
deletion completes even when Plaid refuses the request.

## Consumer rights

Consumers may request access to, correction of, or deletion of their data at
**matthewboustany@gmail.com**, in addition to deleting it themselves in the app.
Depending on jurisdiction, additional rights may apply under laws such as the
GDPR or CCPA; these are honored on request.

The retention periods above are published in the app's privacy policy at
https://mbandhb.com/privacy.

## Known limitations

Recorded plainly, because a policy that lists only strengths is not useful:

- **Backups delay complete erasure by up to 30 days.** Deletion is immediate in
  the live database, but a backup taken before the request retains the data
  until it ages out. This is disclosed in the privacy policy.
- **The database encryption key resides on the same host as the database.**
  Key destruction is therefore an effective disposal method for retired media,
  but not a defense against compromise of the running host.
- There is no automated attestation that disposal completed; verification is a
  manual check by the operator at the review cadence above.
