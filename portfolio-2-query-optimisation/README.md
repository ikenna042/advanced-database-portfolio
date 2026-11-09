# Portfolio 2: Query Processing and Optimisation

Eleven queries that serve real Kolaro Wallet operations were measured on a year of synthetic data, before and after indexing. Several were also rewritten, and four experiments tested index types, partitioning and the planner's estimates.

## Headline results

Median of 5 warm runs, measured as PostgreSQL's execution time. All 11 queries returned exactly the same result in both phases.

| Query | Operation | Baseline (ms) | Indexed (ms) | Change |
|---|---|---:|---:|---:|
| Q1 | Customer statement, busy wallet | 111.5 | 13.4 | 8.3x faster |
| **Q1b** | **Q1, rewritten** | 208.0 | **0.42** | **499x faster** |
| Q2a | Find a customer by email, as first written | 7.5 | 8.2 | No change |
| **Q2b** | **Q2a, rewritten to match the index** | **0.09** | 0.09 | **80x faster than Q2a** |
| Q3 | Daily volume by type, one month | 323.6 | 254.2 | 1.3x faster |
| **Q3b** | **Q3, rewritten** | 296.5 | **43.0** | **6.9x faster** |
| Q4 | Top 10 merchants, one month | 84.8 | 17.6 | 4.8x faster |
| Q5 | Reconcile every wallet balance | 1,376.7 | 669.8 | 2.1x faster |
| Q6 | Latest 50 failed transfers | 35.6 | 0.73 | 49x faster |
| Q7 | Three-hop money trail (recursive) | 437.4 | 0.31 | 1,430x faster |
| Q8 | Count dormant wallets | 111.3 | 157.6 | **1.4x slower** |

The full table is in [evidence/summary.md](evidence/summary.md), and every run is in [evidence/timings.csv](evidence/timings.csv).

## How to run it

From the repository root, with the lab running:

```bash
./portfolio-2-query-optimisation/run.sh
```

It rebuilds the schema, generates the data, verifies it, benchmarks both phases, runs the experiments and rewrites [evidence/](evidence/). The whole run took about 2 minutes 40 seconds.

## Data set

[seed/seed.sql](seed/seed.sql) generates a year of activity, from November 2025 to October 2026, on top of the Portfolio 1 sample data. It uses a fixed random seed, so every run produces the same data.

| Table | Rows |
|---|---:|
| customers | 100,003 |
| wallets | 102,005 |
| ledger_transactions | 2,077,999 |
| ledger_entries | 4,155,998 (271 MB) |
| transfers | 1,538,567 |

**Realistic skew.** Customers are picked using the square of a random number, so a few are very busy. The busiest wallet has 6,270 entries and the median wallet has 25. Q1 and Q7 use the busiest wallet, `1100000001`.

**Faster loading, then a full check.** Triggers were switched off during loading, which also switches off foreign key checks. [seed/verify.sql](seed/verify.sql) then checks every rule they would have enforced, and all nine checks found 0 violations. The checks are in [evidence/data-verification.txt](evidence/data-verification.txt).

**Opening deposits.** Random spending pushed 77,993 wallets below zero at some point. Each of those wallets received an opening deposit, dated when it opened. These deposits sit at the end of the table with early dates, which affects the BRIN result in E1.

**Wallet numbers.** These are built from the generated customer number, not the identity value. The first version used identity values, but the Portfolio 1 tests use up some of them when their deliberately failing inserts roll back. The wallet the queries looked for then didn't exist.

## Method

- **Baseline:** only the keys and constraints from Portfolio 1.
- **Indexed:** the five indexes in [sql/indexes.sql](sql/indexes.sql), each chosen by reading the baseline plans.
- **Measurement:** [bench.sh](bench.sh) saves one `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` plan per query, in [evidence/plans/](evidence/plans/). It saves each query's result for comparison, in [evidence/results/](evidence/results/). It then runs each query once to warm the cache, and five more times with `EXPLAIN (ANALYZE, TIMING OFF)` to record execution time.
- **Environment:** PostgreSQL 16.15 on OrbStack, with 8 CPUs, a 4 GB VM and the default memory settings: `shared_buffers` 128 MB and `work_mem` 4 MB. Details are in [evidence/environment.txt](evidence/environment.txt).

**Variation between runs.** Across three full runs, some medians changed by up to 2x. For example, Q1's baseline was 95, 195 and 111 ms. The table above comes from the final run. Treat differences under about 2x as noise, especially for Q2, Q3 and Q5.

## Indexes added

| Index | Type | Size | Build time | Serves |
|---|---|---:|---:|---|
| `ledger_entries_wallet_time` | B-tree on `(wallet_id, created_at DESC, entry_id DESC)`, covering `amount_kobo, transaction_id` | 233 MB | 2.2 s | Q1, Q4, Q5 |
| `ledger_transactions_created_brin` | BRIN on `created_at` | 24 kB | 0.3 s | Q3 |
| `ledger_entries_created_brin` | BRIN on `created_at` | 24 kB | 0.7 s | Q3b |
| `transfers_failed_recent` | Partial B-tree, `WHERE status = 'failed'` | 880 kB | 0.2 s | Q6 |
| `transfers_source_time` | Partial B-tree, `WHERE status = 'completed'` | 45 MB | 0.9 s | Q7 |

## Analysis, query by query

**Q1, customer statement: an index wasn't enough, and a rewrite fixed it.**
The baseline read all 4.2 million entries in parallel. The new covering index found the wallet's 6,270 entries with an index-only scan. But the plan then joined every one of them to `ledger_transactions` (6,270 lookups) and sorted them, before keeping 50.
- **Why:** the planner estimated 41 rows. E4 shows why: the wallet is found through a join, so the planner can't use its statistics for this specific wallet and assumes an average one.
- **Fix:** Q1b takes the newest 50 entries first, in index order, and joins afterwards. The balance after each entry depends only on newer entries, and those are all among the 50, so the result is identical.
- **Result:** 0.42 ms.

**Q2, lookup by email: an index exists, but the query can't use it.**
The unique index is on `lower(email)`. `WHERE email = ...` is a different expression, so the planner can't use that index and scans all 100,000 customers.
- **Fix:** rewriting the condition as `lower(email) = lower(...)` lets it use the index, which takes about 0.09 ms in both phases.
- **Bonus:** the rewrite is also case-insensitive, which is what support staff need.

**Q3, monthly report: a BRIN index on the wrong side of the join.**
The BRIN index found October's transactions quickly. But the join still read every entry, through a parallel sequential scan, a hash join and a small sort that spilled to disk.
- **Fix:** Q3b also filters entries by date. That's safe because an entry and its transaction share a `created_at` (`now()` is fixed for a whole database transaction). A BRIN index on the entries then skips the other months.
- **Result:** 43 ms.

**Q4, top merchants: 4.8x faster.**
The planner visits each merchant wallet's October range in the covering index, instead of scanning every entry.

**Q5, reconciliation: an index can't avoid reading everything.**
Proving that every wallet balances means summing all 4.2 million entries. The index allowed an ordered index-only merge join, and the median halved, but this run-to-run variation is within the noise.
- **Real fix:** a design change rather than an index. Reconcile only wallets that changed since the last run, or keep daily totals.

**Q6, failed transfers queue: a partial index.**
About 2.5% of transfers fail. The partial index holds only those rows, in date order, so the newest 50 are its first 50 entries. The index is 880 kB, compared with 137 MB for the table.

**Q7, money trail: the largest gain, at 1,430x.**
Without an index, each recursion step scanned all 1.5 million transfers. With an index on `(source_wallet_id, created_at)`, each hop becomes a few small lookups.
- **Why the gain is so large:** recursive queries multiply the cost of a missing index by the number of steps.

**Q8, dormant wallets: the index made it slower.**
The planner switched from one hash anti-join over recent entries to 100,000 separate index lookups, one per wallet. It estimated those as cheaper, but they weren't (E4).
- **Possible fixes:** the original plan, with no secondary index, was the fastest of the three plans tried. This is a batch report, so 160 ms is acceptable. The options are to accept it, or to run it with planner settings changed for that session only.
- **Lesson:** adding indexes can change plans for the worse, so they need re-measuring as a whole.

## Experiments

| Experiment | Finding | Evidence |
|---|---|---|
| **E1: BRIN or B-tree** for date ranges | The B-tree is faster: 9.1 ms versus 18.7 ms for a month, and 0.05 ms versus 5.1 ms for an hour. But it is 45 MB, against 24 kB for the BRIN. A BRIN index suits month-sized ranges on append-only tables, and needs rows stored in date order; here the correlation is 0.79 because of the opening deposits. | [e1](evidence/experiments/e1_brin_vs_btree.txt) |
| **E2: indexing a four-value column** | The rare value (`reversal`, 1 row) used the index in 0.03 ms. The common value (`transfer`, 72% of rows) also used it, with an index-only scan of the 14 MB index rather than the 142 MB table, because the query only counts rows. A query that needs other columns wouldn't benefit. Selectivity and query shape matter, not just how many distinct values a column has. | [e2](evidence/experiments/e2_low_cardinality_index.txt) |
| **E3: monthly partitions** | Partition pruning read only October: 42 ms, against 47 ms for BRIN on the plain table. That's almost no gain at this size. Removing a month took 16 ms with `DETACH`, where a `DELETE` would rewrite and vacuum thousands of pages. The costs: no primary key on `entry_id` alone, no `UNIQUE (transaction_id, wallet_id)`, and queries without a date filter visit all 20 partitions. **Decision: don't partition yet.** It becomes worthwhile when old data has to be archived. | [e3](evidence/experiments/e3_partitioning.txt) |
| **E4: planner estimates** | The busy wallet is in the statistics' most-common-values list. With a literal `wallet_id`, the estimate is 5,818 rows (actual: 6,270). Through a join, as in Q1, it's 91, because the planner doesn't know which wallet until run time. For Q8, the nested loop took 168 ms and the hash anti-join 149 ms. | [e4](evidence/experiments/e4_planner_estimates.txt) |

## Workload statistics

`pg_stat_statements` recorded every query three times. The report is in [evidence/pg-stat-statements.txt](evidence/pg-stat-statements.txt). Q5 used the most total time, and its blocks were mostly served from memory. Q3 and Q8 each read about 104,000 blocks from disk, more than any other query. Those three are where a production system would look first.

## Conclusions

1. **Read the plan before adding indexes.** Q1, Q2 and Q3 showed the biggest gains through rewrites, not just indexes.
2. **Keep the planner's estimates in mind.** Q1 and Q8 went wrong because the estimates were far from reality.
3. **Indexes have costs.** The covering index is 233 MB, almost as big as its table, and slows every insert. Q8 got slower. The partial and BRIN indexes gave large gains at almost no size.
4. **Some queries need a design change.** No index makes Q5 cheap. Incremental reconciliation would.

## Tools and references

- PostgreSQL 16 documentation: [Using EXPLAIN](https://www.postgresql.org/docs/16/using-explain.html), [Index types](https://www.postgresql.org/docs/16/indexes-types.html), [BRIN indexes](https://www.postgresql.org/docs/16/brin-intro.html), [Partitioning](https://www.postgresql.org/docs/16/ddl-partitioning.html), [Planner statistics](https://www.postgresql.org/docs/16/planner-stats.html), [pg_stat_statements](https://www.postgresql.org/docs/16/pgstatstatements.html)
