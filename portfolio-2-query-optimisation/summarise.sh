#!/usr/bin/env bash
# Builds evidence/summary.md: the median execution time of each query in each phase,
# and whether the indexed phase returned exactly the same result as the baseline.
set -euo pipefail
cd "$(dirname "$0")"

median() {
  grep "^$1,$2," evidence/timings.csv | cut -d, -f4 | sort -n \
    | awk '{ v[NR] = $1 } END { if (NR == 0) print "n/a"; else if (NR % 2) print v[(NR + 1) / 2]; else print (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

{
  echo "| Query | Baseline median (ms) | Indexed median (ms) | Speed-up | Same result? |"
  echo "|---|---:|---:|---:|---|"
  for file in queries/*.sql; do
    name=$(basename "$file" .sql)
    before=$(median baseline "$name")
    after=$(median indexed "$name")
    speedup=$(awk -v b="$before" -v a="$after" 'BEGIN { if (a > 0) printf "%.1fx", b / a; else print "n/a" }')
    if cmp -s "evidence/results/baseline/$name.txt" "evidence/results/indexed/$name.txt"; then same=Yes; else same=No; fi
    echo "| $name | $before | $after | $speedup | $same |"
  done
} > evidence/summary.md

cat evidence/summary.md
