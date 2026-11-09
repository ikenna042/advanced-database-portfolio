-- Q3b. The same report with the date range also applied to the entries. An entry and its
-- transaction get the same created_at, because now() is fixed for a whole database
-- transaction, so the extra condition doesn't change the answer. It lets PostgreSQL
-- skip entries outside October instead of joining all 4 million.
SELECT t.created_at::DATE AS day,
       t.txn_type,
       count(*) AS transactions,
       sum(e.amount_kobo) AS value_kobo
  FROM wallet.ledger_transactions t
  JOIN wallet.ledger_entries e ON e.transaction_id = t.transaction_id AND e.amount_kobo > 0
 WHERE t.created_at >= TIMESTAMPTZ '2026-10-01'
   AND t.created_at <  TIMESTAMPTZ '2026-11-01'
   AND e.created_at >= TIMESTAMPTZ '2026-10-01'
   AND e.created_at <  TIMESTAMPTZ '2026-11-01'
 GROUP BY 1, 2
 ORDER BY 1, 2;
