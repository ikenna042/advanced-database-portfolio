#!/usr/bin/env bash
# Rebuilds the Kolaro schema from nothing, loads sample data, runs the tests and saves the evidence.
# This deletes anything already in the wallet schema.
set -euo pipefail

cd "$(dirname "$0")"
EVIDENCE=evidence
mkdir -p "$EVIDENCE"

psql() { docker compose -f ../docker-compose.yml exec -T postgres psql -v ON_ERROR_STOP=1 -U kolaro -d kolaro "$@"; }

for file in sql/01_schema.sql sql/02_rules.sql sql/03_views.sql sql/04_sample_data.sql; do
  echo "Applying $file"
  psql -q < "$file"
done

echo "Running constraint tests"
psql -q < tests/constraint_tests.sql > "$EVIDENCE/constraint-test-results.txt" 2>&1
psql -q < tests/data_checks.sql > "$EVIDENCE/sample-data-checks.txt" 2>&1
psql -q < tests/catalog_report.sql > "$EVIDENCE/schema-catalog.txt" 2>&1

cat "$EVIDENCE/constraint-test-results.txt"
# The summary row must show at least one test and zero failures.
if ! grep -Eq '^ +[1-9][0-9]* \| +[0-9]+ \| +0$' "$EVIDENCE/constraint-test-results.txt"; then
  echo "Constraint tests failed or did not run." >&2
  exit 1
fi
echo "Evidence saved in portfolio-1-database-design/$EVIDENCE/"
