-- Q1b. The same statement, rewritten to pick the 50 entries first and join afterwards.
-- The balance after each entry only depends on newer entries, which are all in those 50,
-- so the result is identical to Q1.
SELECT e.created_at,
       t.txn_type,
       t.narration,
       e.amount_kobo,
       w.balance_kobo - coalesce(sum(e.amount_kobo) OVER (
           ORDER BY e.created_at DESC, e.entry_id DESC
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS balance_after_kobo
  FROM wallet.wallets w
 CROSS JOIN LATERAL (
        SELECT entry_id, created_at, amount_kobo, transaction_id
          FROM wallet.ledger_entries
         WHERE wallet_id = w.wallet_id
         ORDER BY created_at DESC, entry_id DESC
         LIMIT 50) AS e
  JOIN wallet.ledger_transactions t ON t.transaction_id = e.transaction_id
 WHERE w.wallet_number = '1100000001'
 ORDER BY e.created_at DESC, e.entry_id DESC;
