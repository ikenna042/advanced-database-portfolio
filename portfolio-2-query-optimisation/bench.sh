#!/usr/bin/env bash
# Runs every query in queries/ for one phase (for example "baseline" or "indexed"). For each query it:
#   1. saves one full plan from EXPLAIN (ANALYZE, BUFFERS),
#   2. saves the query's actual result, so phases can be checked for identical answers,
#   3. runs it once to warm the cache, then 5 more times, recording PostgreSQL's execution time.
set -euo pipefail

PHASE=${1:?usage: bench.sh <phase>}
RUNS=5
cd "$(dirname "$0")"
mkdir -p "evidence/plans/$PHASE" "evidence/results/$PHASE"
TIMINGS=evidence/timings.csv
[ -f "$TIMINGS" ] || echo "phase,query,run,execution_ms" > "$TIMINGS"
# Replace any earlier timings for this phase.
grep -v "^$PHASE," "$TIMINGS" > "$TIMINGS.tmp" || true
mv "$TIMINGS.tmp" "$TIMINGS"

psql() { docker compose -f ../docker-compose.yml exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U kolaro -d kolaro "$@"; }

for file in queries/*.sql; do
  name=$(basename "$file" .sql)
  echo "[$PHASE] $name"

  { echo "EXPLAIN (ANALYZE, BUFFERS, SETTINGS)"; grep -v '^--' "$file"; } | psql > "evidence/plans/$PHASE/$name.txt"
  psql -P pager=off < "$file" > "evidence/results/$PHASE/$name.txt"

  for run in $(seq 0 "$RUNS"); do
    ms=$({ echo "EXPLAIN (ANALYZE, TIMING OFF)"; grep -v '^--' "$file"; } | psql -At \
         | sed -n 's/^Execution Time: \([0-9.]*\) ms$/\1/p')
    [ "$run" -eq 0 ] && continue  # warm-up run is not recorded
    echo "$PHASE,$name,$run,$ms" >> "$TIMINGS"
  done
done
