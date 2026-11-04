-- A small synthetic data set that walks through each key operation.
-- Portfolio 2 generates the large data set for performance testing.
SET search_path = wallet, public;

INSERT INTO kyc_tiers (tier, daily_limit_kobo, max_balance_kobo) VALUES
    (1,    5000000,  30000000),
    (2,   20000000,  50000000),
    (3,  500000000,      NULL);

INSERT INTO banks (bank_code, bank_name) VALUES
    ('001', 'Example Commercial Bank'),
    ('002', 'Sample Microfinance Bank'),
    ('003', 'Demo Trust Bank');

INSERT INTO staff (full_name, email, role) VALUES
    ('Support Agent One',   'support.one@kolaro.example',   'support'),
    ('Compliance Officer',  'compliance@kolaro.example',    'compliance'),
    ('Finance Lead',        'finance@kolaro.example',       'finance');

INSERT INTO customers (full_name, email, phone, date_of_birth) VALUES
    ('Test Customer Alpha', 'alpha@customers.example', '+2348000000001', '1990-03-14'),
    ('Test Customer Bravo', 'bravo@customers.example', '+2348000000002', '1985-11-02'),
    ('Test Customer Delta', 'delta@customers.example', '+2348000000003', '2001-07-21');

INSERT INTO merchants (business_name, rc_number, category)
VALUES ('Sample Groceries Ltd', 'RC000001', 'grocery');

INSERT INTO wallets (wallet_number, wallet_type, system_code)
VALUES ('0000000001', 'system', 'SETTLEMENT');

INSERT INTO wallets (wallet_number, wallet_type, customer_id)
SELECT '10000000' || lpad(customer_id::TEXT, 2, '0'), 'customer', customer_id FROM customers;

INSERT INTO wallets (wallet_number, wallet_type, merchant_id)
SELECT '20000000' || lpad(merchant_id::TEXT, 2, '0'), 'merchant', merchant_id FROM merchants;

INSERT INTO kyc_documents (customer_id, document_type, document_number)
SELECT customer_id, 'nin', 'SYNTH-NIN-' || customer_id FROM customers;

INSERT INTO kyc_reviews (document_id, tier, status, reviewed_by, reviewed_at)
SELECT d.document_id, 1, 'approved',
       (SELECT staff_id FROM staff WHERE role = 'compliance'), now()
  FROM kyc_documents d;

-- Posts a balanced two-entry transaction and updates both stored balances.
-- Portfolio 3 replaces this with a concurrency-safe procedure.
CREATE FUNCTION pg_temp.post(p_type TEXT, p_narration TEXT, p_from CHAR(10), p_to CHAR(10), p_kobo BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    txn BIGINT;
BEGIN
    INSERT INTO wallet.ledger_transactions (txn_type, narration)
    VALUES (p_type, p_narration)
    RETURNING transaction_id INTO txn;

    INSERT INTO wallet.ledger_entries (transaction_id, wallet_id, amount_kobo)
    SELECT txn, wallet_id, CASE WHEN wallet_number = p_from THEN -p_kobo ELSE p_kobo END
      FROM wallet.wallets WHERE wallet_number IN (p_from, p_to);

    UPDATE wallet.wallets
       SET balance_kobo = balance_kobo + CASE WHEN wallet_number = p_from THEN -p_kobo ELSE p_kobo END,
           version = version + 1
     WHERE wallet_number IN (p_from, p_to);

    RETURN txn;
END $$;

CREATE FUNCTION pg_temp.wallet_id(p_number CHAR(10)) RETURNS BIGINT
LANGUAGE sql AS $$ SELECT wallet_id FROM wallet.wallets WHERE wallet_number = p_number $$;

DO $$
DECLARE
    txn     BIGINT;
    rev     BIGINT;
    settle  CONSTANT CHAR(10) := '0000000001';
    alpha   CONSTANT CHAR(10) := '1000000001';
    bravo   CONSTANT CHAR(10) := '1000000002';
    grocer  CONSTANT CHAR(10) := '2000000001';
BEGIN
    -- Alpha deposits N100,000.
    txn := pg_temp.post('deposit', 'Bank transfer deposit', settle, alpha, 10000000);
    INSERT INTO deposits (wallet_id, amount_kobo, channel, external_reference, status, transaction_id)
    VALUES (pg_temp.wallet_id(alpha), 10000000, 'bank_transfer', 'EXT-DEP-0001', 'completed', txn);

    -- Alpha sends Bravo N25,000.
    txn := pg_temp.post('transfer', 'Rent contribution', alpha, bravo, 2500000);
    INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, transaction_id)
    VALUES (pg_temp.wallet_id(alpha), pg_temp.wallet_id(bravo), 2500000, 'completed', txn);
    INSERT INTO idempotency_keys (customer_id, idempotency_key, request_hash, transaction_id)
    SELECT customer_id, 'sample-key-0001', 'sample-hash-0001', txn FROM wallets WHERE wallet_number = alpha;

    -- Alpha pays the merchant N8,500.
    txn := pg_temp.post('transfer', 'Groceries', alpha, grocer, 850000);
    INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, transaction_id)
    VALUES (pg_temp.wallet_id(alpha), pg_temp.wallet_id(grocer), 850000, 'completed', txn);

    -- Bravo withdraws N5,000 to a bank account.
    txn := pg_temp.post('withdrawal', 'Withdrawal to bank', bravo, settle, 500000);
    INSERT INTO withdrawals (wallet_id, amount_kobo, bank_code, bank_account_number, status, transaction_id)
    VALUES (pg_temp.wallet_id(bravo), 500000, '001', '0123456789', 'completed', txn);

    -- Delta tries to send money with an empty wallet. The request fails, so nothing is posted.
    INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, failure_reason)
    VALUES (pg_temp.wallet_id('1000000003'), pg_temp.wallet_id(bravo), 100000, 'failed', 'insufficient funds');

    -- Alpha sends Bravo N1,000 by mistake, and finance reverses it.
    txn := pg_temp.post('transfer', 'Sent in error', alpha, bravo, 100000);
    rev := pg_temp.post('reversal', 'Reversal of transfer sent in error', bravo, alpha, 100000);
    INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, transaction_id)
    VALUES (pg_temp.wallet_id(alpha), pg_temp.wallet_id(bravo), 100000, 'reversed', txn);
    INSERT INTO reversals (original_transaction_id, reversal_transaction_id, reason, requested_by, approved_by)
    SELECT txn, rev, 'Customer reported wrong recipient',
           (SELECT staff_id FROM staff WHERE role = 'support'),
           (SELECT staff_id FROM staff WHERE role = 'finance');

    -- Compliance freezes Delta's wallet. The trigger writes the audit row.
    PERFORM set_config('kolaro.staff_id',
                       (SELECT staff_id::TEXT FROM staff WHERE role = 'compliance'), TRUE);
    UPDATE wallets SET status = 'frozen' WHERE wallet_number = '1000000003';
END $$;
