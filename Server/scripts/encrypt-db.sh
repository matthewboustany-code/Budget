#!/usr/bin/env bash
# One-time migration: plaintext budget.sqlite -> SQLCipher-encrypted.
#
#   Server/scripts/encrypt-db.sh
#
# Uses SQLCipher's `sqlcipher_export`, which streams every page through the
# cipher into a new file. It is not an in-place rewrite: the original is left
# untouched until the copy is verified, so a failure loses nothing.
#
# Stops the server first — copying a database out from under a live writer is
# how you get a torn backup.
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

# The inner script goes in on stdin (`sh -s`) rather than as a -c argument, so
# there is only one level of shell quoting to reason about. The key is read from
# the container's own environment (compose loads .env for the service), so it
# never appears in the host's process list.
docker compose -f "$compose_file" run --rm --no-deps -T --entrypoint sh server -s <<'INNER'
set -eu
cd /data

[ -f budget.sqlite ] || { echo "no budget.sqlite in /data"; exit 1; }

# A plaintext SQLite file starts with this magic; an encrypted one does not.
if head -c 15 budget.sqlite | grep -q "SQLite format 3"; then
  echo "Found a plaintext database. Encrypting…"
else
  echo "budget.sqlite is already encrypted. Nothing to do."
  exit 0
fi

rm -f budget-encrypted.sqlite

# Fold any WAL content into the main file so nothing is left behind.
sqlcipher budget.sqlite "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null

before=$(sqlcipher budget.sqlite "SELECT count(*) FROM sqlite_master;")

sqlcipher budget.sqlite <<SQL
ATTACH DATABASE '/data/budget-encrypted.sqlite' AS enc KEY '$BUDGET_DB_ENCRYPTION_KEY';
SELECT sqlcipher_export('enc');
DETACH DATABASE enc;
SQL

echo "Verifying the encrypted copy…"
# PRAGMA key must be the first statement on the connection, so these go in
# together on stdin rather than as a command-line argument.
# `.output` silences the pragma's own "ok" row, which would otherwise end up
# in the captured value and fail every comparison below.
after=$(sqlcipher budget-encrypted.sqlite <<SQL
.output /dev/null
PRAGMA key = '$BUDGET_DB_ENCRYPTION_KEY';
.output stdout
SELECT count(*) FROM sqlite_master;
SQL
)
integrity=$(sqlcipher budget-encrypted.sqlite <<SQL
.output /dev/null
PRAGMA key = '$BUDGET_DB_ENCRYPTION_KEY';
.output stdout
PRAGMA integrity_check;
SQL
)

echo "  schema objects: $before -> $after"
echo "  integrity_check: $integrity"
[ "$before" = "$after" ] || { echo "MISMATCH — leaving the original in place"; exit 1; }
[ "$integrity" = "ok" ]  || { echo "INTEGRITY FAILED — leaving the original in place"; exit 1; }

# Confirm the new file really is encrypted before we trust it with the data.
if head -c 15 budget-encrypted.sqlite | grep -q "SQLite format 3"; then
  echo "The 'encrypted' copy still has a plaintext header — refusing to swap it in."
  exit 1
fi

mv budget.sqlite budget-plaintext.sqlite.bak
mv budget-encrypted.sqlite budget.sqlite
rm -f budget.sqlite-wal budget.sqlite-shm
echo "Done. The old plaintext file is /data/budget-plaintext.sqlite.bak"
INNER

echo
echo "Starting the server…"
docker compose -f "$compose_file" up -d server
echo
echo "Once you have confirmed the app works, delete the plaintext original:"
echo "  docker compose -f $compose_file exec server rm /data/budget-plaintext.sqlite.bak"
