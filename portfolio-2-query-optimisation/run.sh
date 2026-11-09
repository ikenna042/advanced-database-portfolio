#!/usr/bin/env bash
# Reproduces all of Portfolio 2 from nothing and rewrites the evidence folder.
# Takes a few minutes. It rebuilds the wallet schema, so any existing data is replaced.
set -euo pipefail

cd "$(dirname "$0")"
psql() { docker compose -f ../docker-compose.yml exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U kolaro -d kolaro "$@"; }

rm -rf evidence
mkdir -p evidence/experiments

echo "1. Rebuilding the Portfolio 1 schema and sample data"
../portfolio-1-database-design/run.sh > /dev/null

echo "2. Generating the large data set"
start=$(date +%s)
psql < seed/seed.sql > evidence/seed-log.txt 2>&1
echo "Seeding took $(( $(date +%s) - start )) seconds" >> evidence/seed-log.txt

echo "3. Verifying the generated data"
psql < seed/verify.sql > evidence/data-verification.txt 2>&1

echo "4. Recording the environment"
{
  echo "Benchmark environment, captured $(date '+%Y-%m-%d %H:%M %Z')"
  docker info --format 'Docker VM: {{.NCPU}} CPUs, {{.MemTotal}} bytes memory, {{.OperatingSystem}}'
  psql -At -c "SELECT version()" \
           -c "SELECT name || ' = ' || setting || coalesce(' ' || unit, '') FROM pg_settings
                WHERE name IN ('shared_buffers', 'work_mem', 'effective_cache_size', 'random_page_cost',
                               'max_parallel_workers_per_gather', 'jit') ORDER BY name"
} > evidence/environment.txt

echo "5. Benchmarking without secondary indexes"
psql < sql/drop_indexes.sql 2>/dev/null
./bench.sh baseline

echo "6. Building indexes and benchmarking again"
psql < sql/indexes.sql > evidence/index-build.txt 2>&1
./bench.sh indexed
./summarise.sh

echo "7. Running the experiments"
for file in experiments/*.sql; do
  name=$(basename "$file" .sql)
  echo "   $name"
  # Not -q, so that timings and expected errors appear in the evidence.
  docker compose -f ../docker-compose.yml exec -T postgres \
    psql -X -v ON_ERROR_STOP=1 -U kolaro -d kolaro < "$file" > "evidence/experiments/$name.txt" 2>&1
done

echo "8. Recording workload statistics"
psql -c "SELECT pg_stat_statements_reset()" > /dev/null
for round in 1 2 3; do
  for file in queries/*.sql; do psql < "$file" > /dev/null; done
done
psql < sql/workload_stats.sql > evidence/pg-stat-statements.txt 2>&1

echo "Done. Evidence is in portfolio-2-query-optimisation/evidence/"
