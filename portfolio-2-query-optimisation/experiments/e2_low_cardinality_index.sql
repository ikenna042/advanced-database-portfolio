-- E2. Is an index on txn_type, a column with only four values, worth having?
SET search_path = wallet, public;
\pset pager off

CREATE INDEX e2_txn_type ON ledger_transactions (txn_type);
ANALYZE ledger_transactions;

\echo '== What the planner knows about txn_type =='
SELECT most_common_vals, most_common_freqs FROM pg_stats
 WHERE schemaname = 'wallet' AND tablename = 'ledger_transactions' AND attname = 'txn_type';

\echo '== A common value: transfer =='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM ledger_transactions WHERE txn_type = 'transfer';

\echo '== A rare value: reversal =='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM ledger_transactions WHERE txn_type = 'reversal';

\echo '== Size of the index =='
SELECT pg_size_pretty(pg_relation_size('e2_txn_type')) AS index_size;

DROP INDEX e2_txn_type;
ANALYZE ledger_transactions;
