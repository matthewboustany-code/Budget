# Budget — Privacy Policy

**Effective date:** 3 September 2026
**Last updated:** 3 September 2026

Budget is a private, self-hosted budgeting app for a single household. It is not
a commercial service and is not offered to the general public. This policy
explains what the app collects, why, where it is stored, and how to have it
deleted.

The app is operated by the individual who runs the server it connects to
("we", "us"). Contact: **matthewboustany@gmail.com**.

## What we collect

**Account identity.** When you sign in with Apple, we receive a stable
identifier unique to this app, and — only if you choose to share it — your name
and email address. We never receive your Apple ID password.

**Financial account data, via Plaid.** If you connect a bank, we use
[Plaid](https://plaid.com/legal/#end-user-privacy-policy) to retrieve, on your
behalf:

- account names, types, masks (last digits), and balances
- transaction dates, amounts, descriptions, merchant names, and categories
- the name of the institution

We never see or receive your online banking username or password. You enter
those directly with Plaid, and Plaid gives us only an access token for the
accounts you approved.

**Data you create.** Budgets, category names, savings goals, notes, comments,
and reactions you add in the app.

**Device tokens.** If you enable bill reminders, we store an Apple push
notification token for your device.

We do not collect analytics, advertising identifiers, location, or contacts.
There is no tracking, and no third-party analytics or advertising SDK in the
app.

## How we use it

Only to make the app work: showing your accounts and transactions, calculating
budgets and net worth, detecting recurring bills, sharing the household view
with the partner you invited, and sending bill reminders if you turn them on.

**We do not sell your data, share it for advertising, or use it to train machine
learning models.** It is not used for any purpose other than operating the app
for you.

## Who we share it with

- **Plaid** — to establish and maintain your bank connections. Plaid's handling
  of your data is governed by its own end user privacy policy, linked above.
- **Apple** — for Sign in with Apple, and to deliver push notifications if you
  enable them.
- **Cloudflare** — the app's traffic reaches the server through Cloudflare,
  which sees connection metadata in transit.

That is the complete list. We do not share your data with anyone else, and we
disclose it to authorities only where legally required.

## Where it is stored and how it is protected

Your data is stored on a private, self-hosted server rather than a commercial
cloud account.

- The database is **encrypted at rest** (SQLCipher, AES-256). Backups are
  encrypted with the same key.
- Bank access tokens are **additionally encrypted** with AES-GCM before being
  written.
- All traffic between the app and the server is **encrypted in transit** with
  TLS. The server accepts no direct inbound connections from the internet;
  everything arrives through an authenticated tunnel.
- Sign in with Apple is the only way in — there are no passwords for us to
  store or leak.
- Within a household, each person controls the visibility of their own accounts
  and transactions. Anything you mark private is hidden from your partner,
  including from shared budgets, reports, and bill detection.

No system is perfectly secure, and we do not claim otherwise. This is a
personal project maintained by one person, not a company with a security team.

## How long we keep it

We keep your data for as long as your account exists. Transactions and balances
are retained so that historical budgets and net-worth trends remain meaningful.

When you delete your account, deletion is **immediate**, not scheduled. We do
not retain a shadow copy.

Encrypted backups are kept for **30 days** on a rolling basis and are then
destroyed automatically. Data you delete may persist in those backups until they
age out.

## Your choices and rights

**Disconnect a bank at any time.** Settings → Connected accounts → Disconnect.
This instructs Plaid to drop the connection and removes those accounts and their
transactions from Budget.

**Delete your account and data.** Settings → Delete account. This disconnects
your banks at Plaid, then erases your accounts, transactions, budgets, goals,
comments, and push tokens. If you are the last member of your household, the
household and everything in it is deleted too. If your partner is still using
it, the shared household remains for them, while your own connected accounts and
their transactions are removed.

This cannot be undone, and we cannot restore a deleted account.

**Access or correct your data.** Email the address above.

Depending on where you live, you may have additional rights over your personal
data — including access, correction, deletion, and portability — under laws such
as the GDPR or the CCPA. Contact us and we will honor them.

## Consent

Connecting a bank is entirely optional, and Plaid asks for your explicit consent
before any connection is made. You can withdraw it at any time by disconnecting
that institution or deleting your account.

## Children

Budget is not intended for anyone under 13, and we do not knowingly collect data
from children.

## Changes

If this policy changes materially, we will update the effective date above and
notify you in the app before the change takes effect.

## Contact

Questions, requests, or complaints: **matthewboustany@gmail.com**
