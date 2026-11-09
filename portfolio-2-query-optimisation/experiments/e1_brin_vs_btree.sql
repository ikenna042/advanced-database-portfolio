-- E1. BRIN or B-tree for date ranges on ledger_transactions?
-- Each query runs twice and only the second, warm-cache plan is shown.
SET search_path = wallet, public;
\pset pager off

\echo '== How closely does physical row order follow created_at? (1.0 = perfectly) =='
SELECT attname, correlation FROM pg_stats
 WHERE schemaname = 'wallet' AND tablename = 'ledger_transactions' AND attname IN ('created_at', 'txn_type');

DROP INDEX IF EXISTS ledger_transactions_created_brin;
CREATE INDEX e1_btree ON ledger_transactions (created_at);
ANALYZE ledger_transactions;

\echo '== B-tree: one month (about 8% of rows) =='
\o /dev/null
SELECT count(*) FROM ledger_transactions WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01';
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM ledger_transactions WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01';

\echo '== B-tree: one hour (about 0.01% of rows) =='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM ledger_transactions WHERE created_at >= '2026-10-15 09:00' AND created_at < '2026-10-15 10:00';

\echo '== B-tree size =='
SELECT pg_size_pretty(pg_relation_size('e1_btree')) AS btree_size;

DROP INDEX e1_btree;
CREATE INDEX ledger_transactions_created_brin ON ledger_transactions USING brin (created_at);
ANALYZE ledger_transactions;

\echo '== BRIN: one month =='
\o /dev/null
SELECT count(*) FROM ledger_transactions WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01';
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM ledger_transactions WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01';

\echo '== BRIN: one hour =='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM ledger_transactions WHERE created_at >= '2026-10-15 09:00' AND created_at < '2026-10-15 10:00';

\echo '== BRIN size =='
SELECT pg_size_pretty(pg_relation_size('ledger_transactions_created_brin')) AS brin_size;
