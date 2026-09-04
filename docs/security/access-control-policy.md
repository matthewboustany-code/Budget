# Access Control Policy — Budget

**Owner:** Matthew Boustany (sole operator)
**Effective date:** 3 September 2026
**Review cadence:** every 6 months, and on any change to who has access
**Last reviewed:** 3 September 2026

## Scope

This policy covers everything that stores or processes consumer financial data
for the Budget app:

- the Debian VM running the API and its database
- the Proxmox hypervisor hosting that VM
- the Cloudflare account fronting it (DNS, tunnel)
- the GitHub repository holding the source
- the Plaid and Apple developer accounts

Budget is operated by one person for one household. This policy is written to be
honest about that rather than to imply a structure that does not exist: there is
no team, no on-call rotation, and no separation of duties, because there is one
operator. What follows is what is actually enforced.

## Principles

1. **Least privilege.** Access is granted only where it is needed to operate the
   service, and nothing runs with more privilege than it requires.
2. **No shared credentials.** Every account belongs to one person. Nothing is
   shared, and no credential is reused across systems.
3. **Fail closed.** Where a control cannot be verified as working, the system
   refuses to run rather than proceeding without it.

## Who has access

| System | Who | Method |
|---|---|---|
| Debian VM (API, database) | Operator only | SSH, key-based |
| Proxmox hypervisor | Operator only | Web console over the LAN |
| Cloudflare | Operator only | Account login with MFA |
| GitHub repository | Operator only | Account login with MFA |
| Plaid dashboard | Operator only | Account login |
| Apple Developer | Operator only | Apple ID with 2FA |

No other person, contractor, or automated third party holds credentials to any
of the above. There are no service accounts belonging to outside parties.

## Human access controls

- **SSH is key-only.** Password authentication is disabled on the VM, and root
  login over SSH is disabled. Access requires possession of the operator's
  private key, which is passphrase-protected. SSH is not reachable from the
  internet — it listens on the local network only.
- **The hypervisor requires MFA.** Proxmox is configured with TOTP in addition
  to the account password.
- **Administrative interfaces are not exposed to the internet.** Proxmox,
  Jellyfin, Home Assistant and similar are reachable only from the local
  network; their DNS names resolve to a private address.
- **The application server publishes no host port at all.** All traffic arrives
  through an authenticated Cloudflare tunnel, so there is no direct inbound path
  to the origin from the internet.

## Non-human and service authentication

- The server authenticates to **APNs** with a short-lived JWT signed by a `.p8`
  key, not a long-lived password.
- The **Cloudflare tunnel** authenticates with tunnel credentials over TLS. The
  account-level certificate is deliberately never placed on the host.
- **Plaid** is accessed with a client ID and environment-specific secret.
- All service-to-service traffic uses TLS.
- Secrets live in a `.env` file readable only by its owner (`chmod 600`), never
  in the repository. The repository is public and its history has been checked
  for credential material.

## Application-level access control (consumer data)

- **Sign in with Apple is the only authentication method.** The app stores no
  passwords, so there are none to leak, reuse, or phish.
- Session tokens are signed JWTs with a 60-day expiry, verified on every request.
- **Authorization is derived server-side**, never from client input: a request's
  household comes from the caller's own membership record. Every lookup by ID
  re-checks household ownership and returns 404 rather than 403, so the API
  cannot be used to probe for the existence of other households' records.
- Within a household, each member controls the visibility of their own accounts
  and transactions; anything marked private is excluded from the partner's
  views, reports, budgets, and recurring-bill detection.
- Sensitive, guessable endpoints are rate limited — invite redemption and
  sign-in — so that a credential or code cannot be attacked by volume.

## Data protection

- The database is **encrypted at rest** with SQLCipher (AES-256). Backups
  inherit that encryption.
- Bank access tokens are **additionally encrypted** with AES-GCM before storage.
- The server **refuses to start** if encryption was requested but the underlying
  library cannot provide it, rather than silently writing plaintext.
- Production **refuses to start** on placeholder secrets or with development
  authentication enabled.

## Review and revocation

- Access is reviewed on the cadence above; because there is exactly one account
  holder per system, a review is a check that no additional accounts, keys, or
  tokens have appeared.
- Credentials are rotated if a device holding them is lost, or on any suspicion
  of compromise.
- There is no employee lifecycle to manage. Should that ever change, this
  policy is updated **before** access is granted, not after.

## Vulnerability management

Scanning runs continuously and without being asked, because a check that
depends on someone remembering is not a control:

- **Dependencies** — Dependabot watches the Swift, Docker and GitHub Actions
  manifests weekly and opens a pull request when a dependency ships a fix.
- **Container image** — Trivy scans lockfiles and manifests on every push, and
  the fully built image weekly. The weekly cadence matters: most
  vulnerabilities appear in code we have not touched.
- **End-of-life software** — Trivy flags EOL base images and packages; the
  server VM runs `unattended-upgrades` for OS security patches.
- Findings are uploaded to GitHub code scanning, so they persist in the
  Security tab with a history rather than scrolling past in a log.

**Remediation targets.** Measured from when the finding appears, not from when
it is noticed:

| Severity | Target |
|---|---|
| Critical | 7 days |
| High | 30 days |
| Medium and below | Next routine dependency update |

Where a fix is unavailable, the exposure is recorded here with whatever
mitigation applies, rather than left as a silently open alert.

## How these controls are enforced

Not aspirations — each of these is applied by something checked into the repo:

| Control | Where it lives |
|---|---|
| SSH key-only, no root login | `Server/scripts/harden-host.sh` |
| Automatic security patching | `Server/scripts/harden-host.sh` (unattended-upgrades) |
| Dependency vulnerability alerts | `.github/dependabot.yml` |
| Container and lockfile scanning | `.github/workflows/security.yml` (Trivy, weekly + per push) |
| Encryption at rest, fail-closed | `Server/Sources/App/Database/AppDatabase.swift` |
| Production secret validation | `Server/Sources/App/AppConfig.swift` |
| Household scoping and privacy | `Server/Sources/App/Routes/*.swift`, covered by tests |
| Rate limiting | `Server/Sources/App/Auth/RateLimiter.swift` |

Proxmox TOTP is the one control configured only in that host's web UI
(Datacenter → Permissions → Two Factor), with no repository artifact.

## Known limitations

Recorded deliberately, because a policy that only lists strengths is not useful:

- The database encryption key resides on the same host as the database. This
  protects a leaked volume, snapshot, backup, or discarded disk; it does not
  protect against compromise of the running host.
- There is no separation of duties and no second reviewer, because there is one
  operator.
- There is no centralized identity provider or SIEM.
- The operator's account is in the `docker` group, which is equivalent to root
  on that host: `sudo` requiring a password does not constrain it. The SSH
  private key is therefore the real boundary for the whole system, and its
  passphrase is the control that protects it.
