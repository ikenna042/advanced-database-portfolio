-- Q2b. The same lookup, rewritten to match the expression index on lower(email).
-- It is also case-insensitive, which is what support staff actually need.
SELECT c.customer_id, c.full_name, w.wallet_number, w.balance_kobo, w.status
  FROM wallet.customers c
  JOIN wallet.wallets w ON w.customer_id = c.customer_id
 WHERE lower(c.email) = lower('Customer50000@customers.example');
