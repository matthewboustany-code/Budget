#!/usr/bin/env bash
# Nightly refresh for cron / the NAS task scheduler:
#   30 2 * * *  /path/to/Budget/Server/scripts/sync-cron.sh
# Runs the balance+transaction sync for every linked Plaid item (which also
# re-detects recurring series and snapshots net worth), then logs bill
# reminders. The webhook keeps transactions fresh during the day; this is the
# safety net that also covers balances and the daily snapshot.
set -uo pipefail
cd "$(dirname "$0")/.."

# cron starts with an empty environment; pull in the compose .env so
# BUDGET_FAIL_WEBHOOK (and anything else) is visible here too.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

mkdir -p logs
log="logs/sync-$(date +%F).log"
{
  echo "=== sync run $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
  docker compose run --rm server sync-all &&
  docker compose run --rm server bill-reminder
} >>"$log" 2>&1
status=$?

if [[ $status -ne 0 && -n "${BUDGET_FAIL_WEBHOOK:-}" ]]; then
  curl -fsS -m 10 -X POST --data "Budget nightly sync failed (exit $status); see $log on the server" \
    "$BUDGET_FAIL_WEBHOOK" || true
fi
exit "$status"
