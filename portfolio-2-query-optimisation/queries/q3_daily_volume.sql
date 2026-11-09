-- Q3. Finance report: daily count and value of each transaction type for October 2026.
SELECT t.created_at::DATE AS day,
       t.txn_type,
       count(*) AS transactions,
       sum(e.amount_kobo) AS value_kobo
  FROM wallet.ledger_transactions t
  JOIN wallet.ledger_entries e ON e.transaction_id = t.transaction_id AND e.amount_kobo > 0
 WHERE t.created_at >= TIMESTAMPTZ '2026-10-01'
   AND t.created_at <  TIMESTAMPTZ '2026-11-01'
 GROUP BY 1, 2
 ORDER BY 1, 2;
