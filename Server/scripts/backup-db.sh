#!/usr/bin/env bash
# Online SQLite backup for cron:
#   0 3 * * *  /path/to/Budget/Server/scripts/backup-db.sh
# Uses sqlite3's `.backup` INSIDE the running server container — WAL-safe
# while the API stays up — writing to the mounted data volume, then prunes
# backups older than $BUDGET_BACKUP_KEEP_DAYS (default 30).
#
# Restore: stop the stack, copy the chosen backup over
# $BUDGET_DATA_DIR/budget.sqlite (removing any -wal/-shm sidecars), start.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

keep_days="${BUDGET_BACKUP_KEEP_DAYS:-30}"
stamp="$(date +%F-%H%M)"

docker compose exec -T server sh -c \
  "mkdir -p /data/backups && sqlite3 /data/budget.sqlite \".backup '/data/backups/budget-$stamp.sqlite'\""

# Prune on the host side of the same volume.
data_dir="${BUDGET_DATA_DIR:-./data}"
find "$data_dir/backups" -name 'budget-*.sqlite' -mtime "+$keep_days" -delete 2>/dev/null || true

echo "Backed up to $data_dir/backups/budget-$stamp.sqlite"
