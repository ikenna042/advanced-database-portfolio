-- Checks the stress wallets after a run. Transfers only move money between these
-- 20 wallets, so their total must still be exactly 20 x 1,000,000 kobo.
SET search_path = wallet, public;
\pset pager off
\pset footer off

\echo '== Is money conserved? =='
SELECT 20 * 1000000                    AS funded_kobo,
       sum(stored_kobo)                AS stored_total_kobo,
       sum(ledger_kobo)                AS ledger_total_kobo,
       sum(stored_kobo) - 20 * 1000000 AS money_created_kobo
  FROM v_wallet_balance_audit WHERE wallet_number LIKE '30%';

\echo '== Do stored balances match the ledger? =='
SELECT count(*) FILTER (WHERE difference_kobo <> 0) AS wallets_wrong,
       coalesce(sum(abs(difference_kobo)), 0)       AS total_error_kobo,
       min(stored_kobo)                             AS lowest_stored_kobo,
       min(ledger_kobo)                             AS lowest_ledger_kobo
  FROM v_wallet_balance_audit WHERE wallet_number LIKE '30%';

\echo '== Whole ledger =='
SELECT entry_count, net_kobo FROM v_ledger_trial_balance;

\echo '== Transfers posted during the run =='
SELECT count(DISTINCT e.transaction_id) AS ledger_transfers
  FROM ledger_entries e
  JOIN ledger_transactions t USING (transaction_id)
  JOIN wallets w USING (wallet_id)
 WHERE w.wallet_number LIKE '30%' AND t.txn_type = 'transfer';
