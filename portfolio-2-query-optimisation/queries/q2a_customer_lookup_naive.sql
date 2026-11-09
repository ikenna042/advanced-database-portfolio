-- Q2a. Support agent finds a customer and their wallet by email, as first written.
-- The unique index is on lower(email), and this condition doesn't use that expression.
SELECT c.customer_id, c.full_name, w.wallet_number, w.balance_kobo, w.status
  FROM wallet.customers c
  JOIN wallet.wallets w ON w.customer_id = c.customer_id
 WHERE c.email = 'customer50000@customers.example';
