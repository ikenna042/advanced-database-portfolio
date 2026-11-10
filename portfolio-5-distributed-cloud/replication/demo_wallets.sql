-- Two wallets used only by the step-by-step demos, 3100000001 and 3100000002, each funded
-- with N50,000 (5,000,000 kobo). Keeping them out of pgbench's 20 stress wallets means
-- the demo transfers can never fail for lack of funds.
SET search_path = wallet, public;

INSERT INTO customers (full_name, email, phone, date_of_birth)
SELECT 'Demo Customer ' || i, 'demo' || i || '@customers.example', '+23482' || lpad(i::TEXT, 8, '0'), DATE '1990-01-01'
  FROM generate_series(1, 2) AS i;

INSERT INTO wallets (wallet_number, wallet_type, customer_id)
SELECT '31' || lpad(substring(email FROM 'demo([0-9]+)@'), 8, '0'), 'customer', customer_id
  FROM customers WHERE email LIKE 'demo%@customers.example';

WITH txn AS (
    INSERT INTO ledger_transactions (txn_type, narration)
    VALUES ('deposit', 'Demo wallet funding')
    RETURNING transaction_id
)
INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
SELECT txn.transaction_id, w.wallet_id, 5000000 FROM txn, wallets w WHERE w.wallet_number LIKE '31%'
UNION ALL
SELECT txn.transaction_id, w.wallet_id, -10000000 FROM txn, wallets w WHERE w.system_code = 'SETTLEMENT';
