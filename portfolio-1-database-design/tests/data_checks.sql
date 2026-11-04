-- Confirms the sample operations left the data consistent.
SET search_path = wallet, public;
\pset pager off
\echo '== Stored balance against ledger, for every wallet (difference must be 0) =='
SELECT wallet_number, wallet_type, stored_kobo, ledger_kobo, difference_kobo
  FROM v_wallet_balance_audit ORDER BY wallet_number;
\echo '== Trial balance (net must be 0) =='
SELECT * FROM v_ledger_trial_balance;
\echo '== Ledger transactions and entries =='
SELECT t.transaction_id, t.txn_type, t.narration, w.wallet_number, e.amount_kobo
  FROM ledger_transactions t
  JOIN ledger_entries e USING (transaction_id)
  JOIN wallets w USING (wallet_id)
 ORDER BY t.transaction_id, e.amount_kobo;
\echo '== Transfer requests, including the failed one with no ledger transaction =='
SELECT transfer_id, amount_kobo, status, failure_reason, transaction_id FROM transfers ORDER BY transfer_id;
\echo '== Reversals =='
SELECT original_transaction_id, reversal_transaction_id, reason, requested_by, approved_by FROM reversals;
\echo '== Audit log (written by the wallet status trigger) =='
SELECT actor_staff_id, action, entity_type, entity_id, details FROM audit_log;
\echo '== Current KYC tier (derived, not stored) =='
SELECT * FROM v_customer_kyc_tier ORDER BY customer_id;
