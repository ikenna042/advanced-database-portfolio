#!/usr/bin/env bash
# Reproduces all of Portfolio 3 and rewrites the evidence folder. Takes about 2 minutes.
# It rebuilds the wallet schema several times, so any existing data is replaced.
# It also kills and restarts the PostgreSQL container once, to test crash recovery.
set -euo pipefail

cd "$(dirname "$0")"
compose() { docker compose -f ../docker-compose.yml "$@"; }
psql() { compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U kolaro -d kolaro "$@"; }

# Runs a demo with the two-session helpers. Errors go to the same stream as results,
# inside the container, so they appear in the right place in the evidence.
demo() {
  echo "   $1"
  cat demos/_sessions.sql "demos/$1.sql" \
    | compose exec -T postgres sh -c 'psql -X -q -v ON_ERROR_STOP=1 -U kolaro -d kolaro 2>&1' \
    > "evidence/$1.txt"
}

deadlocks() { psql -At -c "SELECT deadlocks FROM pg_stat_database WHERE datname = 'kolaro'"; }

# Runs 16 concurrent clients for 15 seconds, then checks the stress wallets.
# $1 = evidence name, $2 = pgbench script, $3 = extra server settings for the clients.
stress() {
  echo "   $1"
  local before; before=$(deadlocks)
  compose exec -T postgres sh -c "cat > /tmp/$2" < "stress/$2"
  {
    echo "Stress run: $1"
    echo "Script: stress/$2, 16 clients, 15 seconds, client settings: ${3:-none}"
    echo
    compose exec -T -e PGOPTIONS="${3:-}" postgres \
      pgbench -U kolaro -n -c 16 -j 4 -T 15 --max-tries=10 --failures-detailed -f "/tmp/$2" kolaro 2>&1 \
      || echo "(pgbench exited with status $?: at least one client stopped on an error it does not retry)"
    echo
    echo "Deadlocks detected by the server during the run: $(( $(deadlocks) - before ))"
    echo
    psql < stress/checks.sql
  } > "evidence/stress-$1.txt"
}

rebuild() { ../portfolio-1-database-design/run.sh > /dev/null; }

rm -rf evidence
mkdir -p evidence

echo "Part A: the plain Portfolio 1 schema, with no Portfolio 3 rules"
rebuild
psql -c "CREATE EXTENSION IF NOT EXISTS dblink SCHEMA public" > /dev/null 2>&1
psql < sql/naive_transfer.sql
demo a1_lost_update

for run in "a-naive-read-committed||" \
           "a-naive-short-deadlock-timeout|-c deadlock_timeout=100ms" \
           "a-naive-serializable|-c default_transaction_isolation=serializable"; do
  rebuild
  psql < sql/naive_transfer.sql
  psql < stress/setup.sql > /dev/null
  stress "${run%%|*}" naive.pgbench "$(echo "$run" | cut -d'|' -f2)"
done

echo "Part B: Portfolio 1 schema plus the Portfolio 3 rules and transfer procedure"
rebuild
psql < sql/01_rules.sql
psql < sql/02_transfer.sql
psql < tests/rule_tests.sql > evidence/rule-tests.txt 2>&1
if ! grep -Eq '^ +[1-9][0-9]* \| +[0-9]+ \| +0$' evidence/rule-tests.txt; then
  echo "Rule tests failed or did not run. See evidence/rule-tests.txt" >&2
  exit 1
fi

demo b1_commit_rollback
demo b2_isolation_levels
demo b3_write_skew
demo b4_locking

echo "   b5_crash_recovery"
{
  echo "=== B5. Durability: kill the server and check what survives ==="
  echo
  echo "[A] commits a N1,000 transfer:"
  psql -c "SELECT transfer_id, status FROM transfer('1000000002', '2000000001', 100000, 'b5-committed', 'Committed before the crash')"
  echo "[B] starts a N2,000 transfer and keeps its transaction open:"
  compose exec -T postgres psql -X -q -U kolaro -d kolaro -c \
    "BEGIN; SELECT transfer('1000000002', '2000000001', 200000, 'b5-uncommitted', 'Open when the server died'); SELECT pg_sleep(60); COMMIT;" \
    > /dev/null 2>&1 &
  sleep 2
  psql -c "SELECT pid, state, left(query, 70) AS query FROM pg_stat_activity WHERE query LIKE 'BEGIN; SELECT transfer%'"
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "Killing the PostgreSQL server with SIGKILL, so it cannot shut down cleanly."
  compose kill -s SIGKILL postgres > /dev/null 2>&1
  wait || true
  compose up -d --wait postgres > /dev/null 2>&1
  echo
  echo "Server log while restarting:"
  compose logs --no-log-prefix --since "$since" postgres | grep -E "not properly shut down|redo|ready to accept" || true
  echo
  echo "After recovery: the committed transfer is there, and nothing from the open one is:"
  psql -c "SELECT narration, count(*) AS ledger_rows FROM ledger_transactions
            WHERE narration IN ('Committed before the crash', 'Open when the server died') GROUP BY narration"
  psql -c "SELECT idempotency_key, transfer_id FROM idempotency_keys WHERE idempotency_key LIKE 'b5-%'"
  psql -c "SELECT (SELECT count(*) FROM v_wallet_balance_audit WHERE difference_kobo <> 0) AS balances_not_matching_ledger,
                  (SELECT count(*) FROM v_request_ledger_mismatches) AS requests_not_matching_ledger,
                  (SELECT net_kobo FROM v_ledger_trial_balance) AS ledger_net_kobo"
} > evidence/b5_crash_recovery.txt 2>&1

psql < stress/setup.sql > /dev/null
stress b-transfer-read-committed safe.pgbench ""
stress b-transfer-serializable safe.pgbench "-c default_transaction_isolation=serializable"

echo "Done. Evidence is in portfolio-3-transactions-concurrency/evidence/"
