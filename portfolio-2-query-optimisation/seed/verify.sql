-- Checks the generated data obeys every rule the disabled triggers would have enforced.
SET search_path = wallet, public;
\pset pager off

\echo '== Row counts =='
SELECT 'customers' AS table_name, count(*) AS row_count FROM customers
UNION ALL SELECT 'merchants', count(*) FROM merchants
UNION ALL SELECT 'wallets', count(*) FROM wallets
UNION ALL SELECT 'ledger_transactions', count(*) FROM ledger_transactions
UNION ALL SELECT 'ledger_entries', count(*) FROM ledger_entries
UNION ALL SELECT 'deposits', count(*) FROM deposits
UNION ALL SELECT 'withdrawals', count(*) FROM withdrawals
UNION ALL SELECT 'transfers', count(*) FROM transfers
UNION ALL SELECT 'kyc_reviews', count(*) FROM kyc_reviews;

\echo '== Rule checks (every violations count must be 0) =='
SELECT 'Transactions that do not net to zero or have fewer than two entries' AS rule, count(*) AS violations
  FROM (SELECT transaction_id FROM ledger_entries GROUP BY transaction_id
         HAVING sum(amount_kobo) <> 0 OR count(*) < 2) AS x
UNION ALL
SELECT 'Transactions with no entries', count(*)
  FROM ledger_transactions t WHERE NOT EXISTS (SELECT 1 FROM ledger_entries e WHERE e.transaction_id = t.transaction_id)
UNION ALL
SELECT 'Whole ledger does not net to zero', (net_kobo <> 0)::INT FROM v_ledger_trial_balance
UNION ALL
SELECT 'Stored balance differs from ledger', count(*) FROM v_wallet_balance_audit WHERE difference_kobo <> 0
UNION ALL
SELECT 'Customer balance ever below zero', count(*)
  FROM (SELECT sum(e.amount_kobo) OVER (PARTITION BY e.wallet_id ORDER BY e.created_at, e.entry_id) AS running
          FROM ledger_entries e JOIN wallets w ON w.wallet_id = e.wallet_id AND w.wallet_type = 'customer') AS r
 WHERE running < 0
UNION ALL
SELECT 'Entries pointing at a missing wallet', count(*)
  FROM ledger_entries e WHERE NOT EXISTS (SELECT 1 FROM wallets w WHERE w.wallet_id = e.wallet_id)
UNION ALL
SELECT 'Entries pointing at a missing transaction', count(*)
  FROM ledger_entries e WHERE NOT EXISTS (SELECT 1 FROM ledger_transactions t WHERE t.transaction_id = e.transaction_id)
UNION ALL
SELECT 'Requests pointing at a missing transaction', count(*)
  FROM (SELECT transaction_id FROM deposits UNION ALL SELECT transaction_id FROM withdrawals
        UNION ALL SELECT transaction_id FROM transfers) AS r
 WHERE r.transaction_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM ledger_transactions t WHERE t.transaction_id = r.transaction_id)
UNION ALL
SELECT 'Transfer amount differs from its ledger entries', count(*)
  FROM transfers t JOIN ledger_entries e
    ON e.transaction_id = t.transaction_id AND e.wallet_id = t.destination_wallet_id
 WHERE e.amount_kobo <> t.amount_kobo;

\echo '== Activity skew: entries per customer wallet =='
SELECT min(c) AS fewest, percentile_cont(0.5) WITHIN GROUP (ORDER BY c) AS median, max(c) AS most
  FROM (SELECT count(*) AS c FROM ledger_entries e
          JOIN wallets w ON w.wallet_id = e.wallet_id AND w.wallet_type = 'customer'
         GROUP BY e.wallet_id) AS x;

\echo '== Wallets used by the benchmark queries =='
SELECT w.wallet_number, count(*) AS entries
  FROM wallets w JOIN ledger_entries e USING (wallet_id)
 WHERE w.wallet_number IN ('1100000001', '1100050000')
 GROUP BY w.wallet_number;

\echo '== Table and index sizes =='
SELECT relname AS table_name,
       pg_size_pretty(pg_table_size(relid)) AS table_size,
       pg_size_pretty(pg_indexes_size(relid)) AS indexes_size
  FROM pg_statio_user_tables
 WHERE schemaname = 'wallet'
 ORDER BY pg_total_relation_size(relid) DESC
 LIMIT 6;
