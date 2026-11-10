#!/usr/bin/env bash
# Copies the Portfolio 2 data set from the main lab's PostgreSQL into the Citus cluster.
# COPY into a distributed table goes through the coordinator, which sends each row to the
# shard that owns its shard key.
set -euo pipefail
cd "$(dirname "$0")"
source_psql() { docker compose -f ../../docker-compose.yml exec -T postgres psql -X -q -U kolaro -d kolaro -v ON_ERROR_STOP=1 "$@"; }
citus_psql() { docker compose exec -T coordinator psql -X -q -U kolaro -d kolaro -v ON_ERROR_STOP=1 "$@"; }

for table in merchants customers wallets ledger_transactions ledger_entries transfers; do
  columns=$(citus_psql -At -c "SELECT string_agg(column_name, ', ' ORDER BY ordinal_position)
                                 FROM information_schema.columns WHERE table_schema = 'wallet' AND table_name = '$table'")
  start=$(date +%s)
  source_psql -c "COPY (SELECT $columns FROM wallet.$table) TO STDOUT" \
    | citus_psql -c "COPY wallet.$table ($columns) FROM STDIN"
  printf '%-20s %9s rows in %3d s\n' "$table" "$(citus_psql -At -c "SELECT count(*) FROM wallet.$table")" $(( $(date +%s) - start ))
done
