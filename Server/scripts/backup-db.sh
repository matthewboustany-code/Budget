#!/usr/bin/env bash
# Online SQLite backup for cron:
#   0 3 * * *  /path/to/Budget/Server/scripts/backup-db.sh
# Uses the sqlcipher CLI's `.backup` INSIDE the running server container —
# WAL-safe while the API stays up — then prunes backups older than
# $BUDGET_BACKUP_KEEP_DAYS (default 30).
#
# The database is encrypted, so the backup is too: `.backup` writes a copy under
# the same key. That means BUDGET_DB_ENCRYPTION_KEY is required to make OR
# restore a backup. Keep a copy of the key somewhere that is not the same place
# as these backups — a backup you cannot decrypt is not a backup, and a backup
# stored next to its key is not encrypted in any way that matters.
#
# Restore: stop the stack, copy the chosen backup over budget.sqlite in the data
# volume (removing any -wal/-shm sidecars), start.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${BUDGET_DB_ENCRYPTION_KEY:?set BUDGET_DB_ENCRYPTION_KEY in .env}"

# Which stack is running. The tunnel and LAN stacks are separate compose files.
compose_file="${BUDGET_COMPOSE_FILE:-docker-compose.tunnel.yml}"
keep_days="${BUDGET_BACKUP_KEEP_DAYS:-30}"
stamp="$(date +%F-%H%M)"

# The key goes in on stdin, never on the command line: an argument would be
# visible in `ps` to every user on the host.
docker compose -f "$compose_file" exec -T server sh -c \
  "mkdir -p /data/backups && sqlcipher /data/budget.sqlite" <<SQL
PRAGMA key = '$BUDGET_DB_ENCRYPTION_KEY';
.backup '/data/backups/budget-$stamp.sqlite'
SQL

# Prune inside the container: the data volume is a named Docker volume, so
# there is no host path to walk.
docker compose -f "$compose_file" exec -T server \
  find /data/backups -name 'budget-*.sqlite' -mtime "+$keep_days" -delete || true

echo "Backed up to /data/backups/budget-$stamp.sqlite (encrypted)"
