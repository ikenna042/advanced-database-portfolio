-- Tries each operation and compares the outcome with what the schema should do.
-- Each attempt runs in its own subtransaction and is undone, so the data is unchanged.
-- Deferred triggers are forced to fire with SET CONSTRAINTS ALL IMMEDIATE.
SET search_path = wallet, public;
\pset pager off

CREATE TEMP TABLE results (
    test_no  INT GENERATED ALWAYS AS IDENTITY,
    test     TEXT,
    expected TEXT,
    actual   TEXT,
    caught_by TEXT,
    outcome  TEXT
);

CREATE FUNCTION pg_temp.attempt(p_test TEXT, p_expected TEXT, p_sql TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_actual TEXT;
    v_caught TEXT := '';
BEGIN
    BEGIN
        EXECUTE p_sql;
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'undo' USING ERRCODE = 'KT001';
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'KT001' THEN
            v_actual := 'accepted';
        ELSE
            v_actual := SQLSTATE;
            GET STACKED DIAGNOSTICS v_caught = CONSTRAINT_NAME;
        END IF;
    END;
    INSERT INTO results (test, expected, actual, caught_by, outcome)
    VALUES (p_test, p_expected, v_actual, v_caught,
            CASE WHEN v_actual = p_expected THEN 'PASS' ELSE 'FAIL' END);
END $$;

\o /dev/null

-- Keys and uniqueness (23505 = unique_violation, 23503 = foreign_key_violation)
SELECT pg_temp.attempt('Duplicate customer email, different case', '23505',
  $q$INSERT INTO customers (full_name, email, phone, date_of_birth)
     VALUES ('Dup', 'ALPHA@customers.example', '+2348000000099', '1990-01-01')$q$);
SELECT pg_temp.attempt('Duplicate customer phone', '23505',
  $q$INSERT INTO customers (full_name, email, phone, date_of_birth)
     VALUES ('Dup', 'new@customers.example', '+2348000000001', '1990-01-01')$q$);
SELECT pg_temp.attempt('Second NGN wallet for one customer', '23505',
  $q$INSERT INTO wallets (wallet_number, wallet_type, customer_id)
     SELECT '1999999999', 'customer', customer_id FROM customers WHERE email = 'alpha@customers.example'$q$);
SELECT pg_temp.attempt('Wallet for a customer that does not exist', '23503',
  $q$INSERT INTO wallets (wallet_number, wallet_type, customer_id) VALUES ('1999999999', 'customer', 999999)$q$);
SELECT pg_temp.attempt('Delete a customer who has linked records', '23503',
  $q$DELETE FROM customers WHERE email = 'alpha@customers.example'$q$);
SELECT pg_temp.attempt('Same KYC document registered to another customer', '23505',
  $q$INSERT INTO kyc_documents (customer_id, document_type, document_number)
     SELECT customer_id, 'nin', 'SYNTH-NIN-1' FROM customers WHERE email = 'bravo@customers.example'$q$);
SELECT pg_temp.attempt('Second approved review, same document and tier', '23505',
  $q$INSERT INTO kyc_reviews (document_id, tier, status, reviewed_by, reviewed_at)
     SELECT document_id, tier, 'approved', reviewed_by, now() FROM kyc_reviews LIMIT 1$q$);
SELECT pg_temp.attempt('Same wallet twice in one transaction', '23505',
  $q$INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
     SELECT transaction_id, wallet_id, 1 FROM ledger_entries LIMIT 1$q$);
SELECT pg_temp.attempt('Reverse the same transaction twice', '23505',
  $q$WITH r AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('reversal', 'again') RETURNING transaction_id)
     INSERT INTO reversals (original_transaction_id, reversal_transaction_id, reason, requested_by, approved_by)
     SELECT v.original_transaction_id, r.transaction_id, 'again', v.requested_by, v.approved_by
       FROM r, reversals v$q$);

-- CHECK constraints (23514 = check_violation)
SELECT pg_temp.attempt('Invalid phone format', '23514',
  $q$INSERT INTO customers (full_name, email, phone, date_of_birth)
     VALUES ('Bad', 'bad@customers.example', '08000000001', '1990-01-01')$q$);
SELECT pg_temp.attempt('Wallet with two owners', '23514',
  $q$INSERT INTO wallets (wallet_number, wallet_type, customer_id, merchant_id, system_code)
     VALUES ('1999999999', 'customer', 3, 1, NULL)$q$);
SELECT pg_temp.attempt('Customer wallet balance below zero', '23514',
  $q$UPDATE wallets SET balance_kobo = -1 WHERE wallet_number = '1000000001'$q$);
SELECT pg_temp.attempt('System wallet balance below zero is allowed', 'accepted',
  $q$UPDATE wallets SET balance_kobo = -1 WHERE wallet_number = '0000000001'$q$);
SELECT pg_temp.attempt('Ledger entry of zero', '23514',
  $q$WITH t AS (SELECT transaction_id FROM ledger_transactions LIMIT 1)
     INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
     SELECT t.transaction_id, 4, 0 FROM t$q$);
SELECT pg_temp.attempt('Transfer to the same wallet', '23514',
  $q$INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo) VALUES (2, 2, 100)$q$);
SELECT pg_temp.attempt('Transfer with zero amount', '23514',
  $q$INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo) VALUES (2, 3, 0)$q$);
SELECT pg_temp.attempt('Completed transfer with no ledger transaction', '23514',
  $q$INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status) VALUES (2, 3, 100, 'completed')$q$);
SELECT pg_temp.attempt('Failed transfer with no reason', '23514',
  $q$INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status) VALUES (2, 3, 100, 'failed')$q$);
SELECT pg_temp.attempt('KYC approved with no reviewer', '23514',
  $q$INSERT INTO kyc_reviews (document_id, tier, status) SELECT document_id, 2, 'approved' FROM kyc_documents LIMIT 1$q$);
SELECT pg_temp.attempt('Reversal requested and approved by one person', '23514',
  $q$WITH r AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('reversal', 'x') RETURNING transaction_id)
     INSERT INTO reversals (original_transaction_id, reversal_transaction_id, reason, requested_by, approved_by)
     SELECT 1, r.transaction_id, 'x', 1, 1 FROM r$q$);

-- Double-entry rule (deferred trigger)
SELECT pg_temp.attempt('Balanced transaction', 'accepted',
  $q$WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'ok') RETURNING transaction_id)
     INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
     SELECT t.transaction_id, v.w, v.a FROM t, (VALUES (2::BIGINT, -100::BIGINT), (3, 100)) AS v (w, a)$q$);
SELECT pg_temp.attempt('Unbalanced transaction', '23514',
  $q$WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'bad') RETURNING transaction_id)
     INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
     SELECT t.transaction_id, v.w, v.a FROM t, (VALUES (2::BIGINT, -100::BIGINT), (3, 99)) AS v (w, a)$q$);
SELECT pg_temp.attempt('Transaction with one entry', '23514',
  $q$WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'bad') RETURNING transaction_id)
     INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo) SELECT t.transaction_id, 2, 100 FROM t$q$);
SELECT pg_temp.attempt('Transaction with no entries', '23514',
  $q$INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'empty')$q$);

-- Reversal mirror rule (deferred trigger)
SELECT pg_temp.attempt('Reversal for the wrong amount', '23514',
  $q$WITH r AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('reversal', 'wrong') RETURNING transaction_id),
          e AS (INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
                SELECT r.transaction_id, v.w, v.a FROM r, (VALUES (2::BIGINT, 1::BIGINT), (1, -1)) AS v (w, a))
     INSERT INTO reversals (original_transaction_id, reversal_transaction_id, reason, requested_by, approved_by)
     SELECT 1, r.transaction_id, 'wrong', 1, 2 FROM r$q$);
SELECT pg_temp.attempt('Reversal using a non-reversal transaction', '23514',
  $q$WITH r AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'wrong type') RETURNING transaction_id),
          e AS (INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
                SELECT r.transaction_id, v.w, v.a FROM r, (VALUES (2::BIGINT, -10000000::BIGINT), (1, 10000000)) AS v (w, a))
     INSERT INTO reversals (original_transaction_id, reversal_transaction_id, reason, requested_by, approved_by)
     SELECT 1, r.transaction_id, 'wrong type', 1, 2 FROM r$q$);

-- Append-only rule (23001 = restrict_violation)
SELECT pg_temp.attempt('Update a ledger entry', '23001', $q$UPDATE ledger_entries SET amount_kobo = 1$q$);
SELECT pg_temp.attempt('Delete a ledger entry', '23001', $q$DELETE FROM ledger_entries$q$);
SELECT pg_temp.attempt('Truncate the ledger entries', '23001', $q$TRUNCATE ledger_entries$q$);
SELECT pg_temp.attempt('Update a ledger transaction', '23001', $q$UPDATE ledger_transactions SET narration = 'edited'$q$);
SELECT pg_temp.attempt('Delete an audit row', '23001', $q$DELETE FROM audit_log$q$);

\o

SELECT test_no, test, expected, actual, caught_by, outcome FROM results ORDER BY test_no;

SELECT count(*) AS tests,
       count(*) FILTER (WHERE outcome = 'PASS') AS passed,
       count(*) FILTER (WHERE outcome = 'FAIL') AS failed
  FROM results;
