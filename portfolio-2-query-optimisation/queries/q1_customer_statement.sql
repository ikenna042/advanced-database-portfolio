-- Q1. Customer statement: the 50 most recent movements on a busy wallet,
-- with the balance after each one (current balance minus every later movement).
SELECT e.created_at,
       t.txn_type,
       t.narration,
       e.amount_kobo,
       w.balance_kobo - coalesce(sum(e.amount_kobo) OVER (
           ORDER BY e.created_at DESC, e.entry_id DESC
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS balance_after_kobo
  FROM wallet.wallets w
  JOIN wallet.ledger_entries e ON e.wallet_id = w.wallet_id
  JOIN wallet.ledger_transactions t ON t.transaction_id = e.transaction_id
 WHERE w.wallet_number = '1100000001'
 ORDER BY e.created_at DESC, e.entry_id DESC
 LIMIT 50;
