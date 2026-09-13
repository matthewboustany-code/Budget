#!/usr/bin/env bash
# Online encrypted backup for cron:
#   0 3 * * *  /path/to/Budget/Server/scripts/backup-db.sh
# Runs sqlcipher INSIDE the running server container while the API stays up,
# verifies the copy, then copies it out of the Docker volume to
# $BUDGET_BACKUP_HOST_DIR (default ~/budget-backups) and prunes both locations
# after $BUDGET_BACKUP_KEEP_DAYS (default 30).
#
# Why not `.backup`: SQLCipher's CLI refuses it on encrypted databases ("backup
# is not supported with encrypted databases") while still exiting 0 and leaving
# a 0-byte file. So we ATTACH a new database under the same key and
# `sqlcipher_export` into it, which runs in one read transaction (a consistent
# snapshot). Every backup is then reopened and must pass integrity_check with
# the same schema-object count as the live DB, or the script fails.
#
# The backup is encrypted under BUDGET_DB_ENCRYPTION_KEY, which is required to
# make OR restore one. Keep a copy of the key somewhere other than this host —
# a backup you cannot decrypt is not a backup.
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
host_dir="${BUDGET_BACKUP_HOST_DIR:-$HOME/budget-backups}"
stamp="$(date +%F-%H%M)"
backup="/data/backups/budget-$stamp.sqlite"
key="${BUDGET_DB_ENCRYPTION_KEY//\'/\'\'}"

# Runs SQL (from stdin) with the key applied. The key goes in on stdin, never on
# the command line: an argument would be visible in `ps` to every user on the
# host. -bail makes any SQL error a nonzero exit.
sql() {
  docker compose -f "$compose_file" exec -T server sqlcipher -bail "$1"
}

docker compose -f "$compose_file" exec -T server sh -c \
  "mkdir -p /data/backups && rm -f '$backup'"

sql /data/budget.sqlite >/dev/null <<SQL
PRAGMA key = '$key';
ATTACH DATABASE '$backup' AS backup KEY '$key';
SELECT sqlcipher_export('backup');
DETACH DATABASE backup;
SQL

live_count="$(sql /data/budget.sqlite <<SQL | tail -1
.output /dev/null
PRAGMA key = '$key';
.output stdout
SELECT count(*) FROM sqlite_master;
SQL
)"
check="$(sql "$backup" <<SQL | tr '\n' ' '
.output /dev/null
PRAGMA key = '$key';
.output stdout
PRAGMA integrity_check;
SELECT count(*) FROM sqlite_master;
SQL
)"
if [[ "$check" != "ok $live_count " ]]; then
  echo "Backup verification FAILED for $backup (got: '$check', live objects: $live_count)" >&2
  exit 1
fi

# Keep a copy outside the Docker volume, so losing or pruning the volume does
# not take the backups with it.
mkdir -p "$host_dir"
chmod 700 "$host_dir"
docker compose -f "$compose_file" cp "server:$backup" "$host_dir/"
chmod 600 "$host_dir/budget-$stamp.sqlite"

# Prune inside the container (named volume, no host path) and on the host.
docker compose -f "$compose_file" exec -T server \
  find /data/backups -name 'budget-*.sqlite' -mtime "+$keep_days" -delete || true
find "$host_dir" -name 'budget-*.sqlite' -mtime "+$keep_days" -delete || true

echo "Backed up to $backup and $host_dir/budget-$stamp.sqlite (encrypted, verified: $live_count objects)"
