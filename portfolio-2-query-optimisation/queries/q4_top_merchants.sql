-- Q4. Top 10 merchants by money received in October 2026.
SELECT m.business_name,
       m.category,
       count(*) AS payments,
       sum(e.amount_kobo) AS received_kobo
  FROM wallet.merchants m
  JOIN wallet.wallets w ON w.merchant_id = m.merchant_id
  JOIN wallet.ledger_entries e ON e.wallet_id = w.wallet_id
 WHERE e.created_at >= TIMESTAMPTZ '2026-10-01'
   AND e.created_at <  TIMESTAMPTZ '2026-11-01'
 GROUP BY m.merchant_id
 ORDER BY received_kobo DESC
 LIMIT 10;
