#!/usr/bin/env bash
# One-time migration: plaintext budget.sqlite -> SQLCipher-encrypted.
#
#   Server/scripts/encrypt-db.sh
#
# Uses SQLCipher's `sqlcipher_export`, which streams every page through the
# cipher into a new file. It is not an in-place rewrite, so the original is left
# untouched until the new file is verified — if anything fails, nothing is lost.
#
# Stop the server first: copying a database out from under a live writer is how
# you get a torn backup.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${BUDGET_DB_ENCRYPTION_KEY:?set BUDGET_DB_ENCRYPTION_KEY in .env first}"
compose_file="${BUDGET_COMPOSE_FILE:-docker-compose.tunnel.yml}"

echo "Stopping the server so the database has no live writer…"
docker compose -f "$compose_file" stop server

# Run against the volume with the server down, using the image's own sqlcipher.
docker compose -f "$compose_file" run --rm --no-deps --entrypoint sh server -c '
  set -e
  cd /data
  if [ ! -f budget.sqlite ]; then echo "no budget.sqlite in /data"; exit 1; fi

  # A plaintext SQLite file starts with this magic; an encrypted one does not.
  if head -c 15 budget.sqlite | grep -q "SQLite format 3"; then
    echo "Found a plaintext database. Encrypting…"
  else
    echo "budget.sqlite is already encrypted (no SQLite header). Nothing to do."
    exit 0
  fi

  rm -f budget-encrypted.sqlite
  # Checkpoint any WAL content into the main file first, so nothing is missed.
  sqlcipher budget.sqlite "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null

  sqlcipher budget.sqlite <<SQL
ATTACH DATABASE '"'"'/data/budget-encrypted.sqlite'"'"' AS enc KEY '"'"'"$BUDGET_DB_ENCRYPTION_KEY"'"'"';
SELECT sqlcipher_export('"'"'enc'"'"');
DETACH DATABASE enc;
SQL

  echo "Verifying the encrypted copy opens and matches…"
  before=$(sqlcipher budget.sqlite "SELECT count(*) FROM sqlite_master;")
  after=$(sqlcipher budget-encrypted.sqlite "PRAGMA key = '"'"'"$BUDGET_DB_ENCRYPTION_KEY"'"'"'; SELECT count(*) FROM sqlite_master;")
  echo "  schema objects: $before -> $after"
  [ "$before" = "$after" ] || { echo "MISMATCH — leaving the original in place"; exit 1; }

  integrity=$(sqlcipher budget-encrypted.sqlite "PRAGMA key = '"'"'"$BUDGET_DB_ENCRYPTION_KEY"'"'"'; PRAGMA integrity_check;")
  echo "  integrity_check: $integrity"
  [ "$integrity" = "ok" ] || { echo "INTEGRITY FAILED — leaving the original in place"; exit 1; }

  mv budget.sqlite budget-plaintext.sqlite.bak
  mv budget-encrypted.sqlite budget.sqlite
  rm -f budget.sqlite-wal budget.sqlite-shm
  echo "Done. The old plaintext file is /data/budget-plaintext.sqlite.bak"
'

echo
echo "Starting the server…"
docker compose -f "$compose_file" up -d server
echo
echo "Once you have confirmed the app works, delete the plaintext backup:"
echo "  docker compose -f $compose_file exec server rm /data/budget-plaintext.sqlite.bak"
