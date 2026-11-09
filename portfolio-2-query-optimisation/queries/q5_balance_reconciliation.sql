-- Q5. Nightly reconciliation: wallets whose stored balance differs from their ledger.
-- The correct answer is no rows, but the database must read every entry to prove it.
SELECT wallet_number, stored_kobo, ledger_kobo, difference_kobo
  FROM wallet.v_wallet_balance_audit
 WHERE difference_kobo <> 0;
