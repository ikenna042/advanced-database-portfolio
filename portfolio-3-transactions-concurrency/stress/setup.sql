-- Creates 20 stress-test customers with wallets 3000000001 to 3000000020, and funds
-- each with N10,000 (1,000,000 kobo) from the settlement wallet in one deposit.
-- Works on both schemas: in Part A the final UPDATE sets the balances; in Part B the
-- ledger trigger has already set them, so the UPDATE matches no rows.
SET search_path = wallet, public;

INSERT INTO customers (full_name, email, phone, date_of_birth)
SELECT 'Stress Customer ' || i, 'stress' || i || '@customers.example',
       '+23481' || lpad(i::TEXT, 8, '0'), DATE '1995-01-01'
  FROM generate_series(1, 20) AS i;

INSERT INTO wallets (wallet_number, wallet_type, customer_id)
SELECT '30' || lpad(substring(email FROM 'stress([0-9]+)@'), 8, '0'), 'customer', customer_id
  FROM customers WHERE email LIKE 'stress%';

WITH txn AS (
    INSERT INTO ledger_transactions (txn_type, narration)
    VALUES ('deposit', 'Stress test funding')
    RETURNING transaction_id
)
INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
SELECT txn.transaction_id, w.wallet_id, 1000000
  FROM txn, wallets w WHERE w.wallet_number LIKE '30%'
UNION ALL
SELECT txn.transaction_id, w.wallet_id, -20000000
  FROM txn, wallets w WHERE w.system_code = 'SETTLEMENT';

UPDATE wallets w
   SET balance_kobo = l.total
  FROM (SELECT wallet_id, sum(amount_kobo) AS total FROM ledger_entries GROUP BY wallet_id) AS l
 WHERE l.wallet_id = w.wallet_id AND w.balance_kobo <> l.total;
