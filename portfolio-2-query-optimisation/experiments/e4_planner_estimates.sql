-- E4. Why did the planner choose badly for Q1 and Q8?
SET search_path = wallet, public;
\pset pager off

SELECT wallet_id AS busy_wallet FROM wallets WHERE wallet_number = '1100000001' \gset

\echo '== Is the busy wallet in the most-common-values statistics for ledger_entries.wallet_id? =='
SELECT (:busy_wallet = ANY (most_common_vals::TEXT::BIGINT[])) AS busy_wallet_in_mcv_list,
       n_distinct
  FROM pg_stats WHERE schemaname = 'wallet' AND tablename = 'ledger_entries' AND attname = 'wallet_id';

\echo '== Estimate when the wallet_id is a literal (the planner can use the statistics) =='
EXPLAIN SELECT * FROM ledger_entries WHERE wallet_id = :busy_wallet;

\echo '== Estimate when the wallet is found through a join, as in Q1 (it cannot) =='
EXPLAIN SELECT e.* FROM wallets w JOIN ledger_entries e ON e.wallet_id = w.wallet_id
 WHERE w.wallet_number = '1100000001';

\echo '== Q8 as the planner chooses it (nested loop with one index probe per wallet) =='
\o /dev/null
SELECT count(*) FROM wallets w
 WHERE w.wallet_type = 'customer' AND w.status = 'active'
   AND NOT EXISTS (SELECT 1 FROM ledger_entries e WHERE e.wallet_id = w.wallet_id AND e.created_at >= '2026-08-01');
\o
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM wallets w
 WHERE w.wallet_type = 'customer' AND w.status = 'active'
   AND NOT EXISTS (SELECT 1 FROM ledger_entries e WHERE e.wallet_id = w.wallet_id AND e.created_at >= '2026-08-01');

\echo '== Q8 with nested loops disabled, for diagnosis only =='
SET enable_nestloop = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM wallets w
 WHERE w.wallet_type = 'customer' AND w.status = 'active'
   AND NOT EXISTS (SELECT 1 FROM ledger_entries e WHERE e.wallet_id = w.wallet_id AND e.created_at >= '2026-08-01');
RESET enable_nestloop;
