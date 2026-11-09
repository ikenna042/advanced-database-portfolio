-- Tests the Portfolio 3 rules and the transfer procedure. Uses the same method as
-- Portfolio 1: each attempt runs in a subtransaction, deferred triggers are forced to
-- fire, and the attempt is then undone, so the data is unchanged.
-- SQLSTATEs: 23514 check_violation, 23001 restrict_violation,
--            22023 invalid_parameter_value, P0002 no_data_found.
SET search_path = wallet, public;
\pset pager off

CREATE TEMP TABLE results (
    test_no   INT GENERATED ALWAYS AS IDENTITY,
    test      TEXT,
    expected  TEXT,
    actual    TEXT,
    caught_by TEXT,
    outcome   TEXT
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

-- Rule 2: balances change only through the ledger
SELECT pg_temp.attempt('Update a balance directly', '23001',
  $q$UPDATE wallets SET balance_kobo = balance_kobo + 100 WHERE wallet_number = '1000000001'$q$);
SELECT pg_temp.attempt('Open a wallet with a non-zero balance', '23514',
  $q$INSERT INTO wallets (wallet_number, wallet_type, system_code, balance_kobo)
     VALUES ('0000000099', 'system', 'TEST', 500)$q$);
SELECT pg_temp.attempt('Ledger entries update both balances', 'accepted',
  $q$WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'test')
               RETURNING transaction_id)
     INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
     SELECT t.transaction_id, w.wallet_id, CASE w.wallet_number WHEN '1000000001' THEN -100 ELSE 100 END
       FROM t, wallets w WHERE w.wallet_number IN ('1000000001', '1000000002');
     DO $d$ BEGIN
         IF EXISTS (SELECT 1 FROM v_wallet_balance_audit WHERE difference_kobo <> 0) THEN
             RAISE EXCEPTION 'balance differs from ledger' USING ERRCODE = 'KT002';
         END IF;
     END $d$$q$);

-- Rule 1: a frozen or closed wallet can't send money (Delta, 1000000003, is frozen)
SELECT pg_temp.attempt('Debit a frozen wallet', '23514',
  $q$WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'test')
               RETURNING transaction_id)
     INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
     SELECT t.transaction_id, w.wallet_id, CASE w.wallet_number WHEN '1000000003' THEN -100 ELSE 100 END
       FROM t, wallets w WHERE w.wallet_number IN ('1000000003', '1000000002')$q$);
SELECT pg_temp.attempt('Credit a frozen wallet', 'accepted',
  $q$WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'test')
               RETURNING transaction_id)
     INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
     SELECT t.transaction_id, w.wallet_id, CASE w.wallet_number WHEN '1000000001' THEN -100 ELSE 100 END
       FROM t, wallets w WHERE w.wallet_number IN ('1000000001', '1000000003')$q$);
SELECT pg_temp.attempt('Reverse money out of a frozen wallet', 'accepted',
  $q$UPDATE wallets SET status = 'frozen' WHERE wallet_number = '1000000002';
     WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('reversal', 'test')
               RETURNING transaction_id)
     INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
     SELECT t.transaction_id, w.wallet_id, CASE w.wallet_number WHEN '1000000002' THEN -100 ELSE 100 END
       FROM t, wallets w WHERE w.wallet_number IN ('1000000002', '1000000001')$q$);
SELECT pg_temp.attempt('Credit a closed wallet', '23514',
  $q$UPDATE wallets SET status = 'closed' WHERE wallet_number = '1000000002';
     WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'test')
               RETURNING transaction_id)
     INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
     SELECT t.transaction_id, w.wallet_id, CASE w.wallet_number WHEN '1000000001' THEN -100 ELSE 100 END
       FROM t, wallets w WHERE w.wallet_number IN ('1000000001', '1000000002')$q$);

-- Rule 3: a request's amount matches its ledger entries
SELECT pg_temp.attempt('Transfer row with a different amount from its ledger entries', '23514',
  $q$WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'test')
               RETURNING transaction_id),
          e AS (INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
                SELECT t.transaction_id, w.wallet_id, CASE w.wallet_number WHEN '1000000001' THEN -100 ELSE 100 END
                  FROM t, wallets w WHERE w.wallet_number IN ('1000000001', '1000000002'))
     INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, transaction_id)
     SELECT (SELECT wallet_id FROM wallets WHERE wallet_number = '1000000001'),
            (SELECT wallet_id FROM wallets WHERE wallet_number = '1000000002'), 200, 'completed', transaction_id
       FROM t$q$);
SELECT pg_temp.attempt('Transfer row whose wallets are the wrong way round', '23514',
  $q$WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('transfer', 'test')
               RETURNING transaction_id),
          e AS (INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
                SELECT t.transaction_id, w.wallet_id, CASE w.wallet_number WHEN '1000000001' THEN -100 ELSE 100 END
                  FROM t, wallets w WHERE w.wallet_number IN ('1000000001', '1000000002'))
     INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, transaction_id)
     SELECT (SELECT wallet_id FROM wallets WHERE wallet_number = '1000000002'),
            (SELECT wallet_id FROM wallets WHERE wallet_number = '1000000001'), 100, 'completed', transaction_id
       FROM t$q$);
SELECT pg_temp.attempt('Transfer row pointing at a deposit transaction', '23514',
  $q$INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, transaction_id)
     SELECT d.wallet_id, (SELECT wallet_id FROM wallets WHERE wallet_number = '1000000002'),
            d.amount_kobo, 'completed', d.transaction_id
       FROM deposits d LIMIT 1$q$);
SELECT pg_temp.attempt('Deposit row with a different amount from its ledger entries', '23514',
  $q$WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('deposit', 'test')
               RETURNING transaction_id),
          e AS (INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
                SELECT t.transaction_id, w.wallet_id, CASE w.wallet_number WHEN '0000000001' THEN -500 ELSE 500 END
                  FROM t, wallets w WHERE w.wallet_number IN ('0000000001', '1000000002'))
     INSERT INTO deposits (wallet_id, amount_kobo, channel, external_reference, status, transaction_id)
     SELECT (SELECT wallet_id FROM wallets WHERE wallet_number = '1000000002'), 5000, 'card', 'EXT-TEST', 'completed',
            transaction_id FROM t$q$);
SELECT pg_temp.attempt('Withdrawal that matches its ledger entries', 'accepted',
  $q$WITH t AS (INSERT INTO ledger_transactions (txn_type, narration) VALUES ('withdrawal', 'test')
               RETURNING transaction_id),
          e AS (INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
                SELECT t.transaction_id, w.wallet_id, CASE w.wallet_number WHEN '1000000002' THEN -500 ELSE 500 END
                  FROM t, wallets w WHERE w.wallet_number IN ('0000000001', '1000000002'))
     INSERT INTO withdrawals (wallet_id, amount_kobo, bank_code, bank_account_number, status, transaction_id)
     SELECT (SELECT wallet_id FROM wallets WHERE wallet_number = '1000000002'), 500, '001', '0123456789',
            'completed', transaction_id FROM t$q$);

-- The transfer procedure rejects malformed requests
SELECT pg_temp.attempt('transfer(): zero amount', '22023',
  $q$SELECT * FROM transfer('1000000001', '1000000002', 0, 'test-zero')$q$);
SELECT pg_temp.attempt('transfer(): to the same wallet', '22023',
  $q$SELECT * FROM transfer('1000000001', '1000000001', 100, 'test-self')$q$);
SELECT pg_temp.attempt('transfer(): unknown wallet', 'P0002',
  $q$SELECT * FROM transfer('1000000001', '1999999999', 100, 'test-unknown')$q$);
SELECT pg_temp.attempt('transfer(): from a merchant wallet', '22023',
  $q$SELECT * FROM transfer('2000000001', '1000000001', 100, 'test-merchant')$q$);
SELECT pg_temp.attempt('transfer(): same key reused for a different amount', '22023',
  $q$SELECT * FROM transfer('1000000001', '1000000002', 100, 'test-reuse');
     SELECT * FROM transfer('1000000001', '1000000002', 999, 'test-reuse')$q$);

\o

SELECT test_no, test, expected, actual, caught_by, outcome FROM results ORDER BY test_no;

SELECT count(*) AS tests,
       count(*) FILTER (WHERE outcome = 'PASS') AS passed,
       count(*) FILTER (WHERE outcome = 'FAIL') AS failed
  FROM results;

\echo
\echo '== What transfer() returns in each business case (rolled back afterwards) =='
BEGIN;
SELECT 'Normal transfer' AS case_, * FROM transfer('1000000001', '1000000002', 100000, 'case-1')
UNION ALL
SELECT 'Same request sent again', * FROM transfer('1000000001', '1000000002', 100000, 'case-1')
UNION ALL
SELECT 'From a frozen wallet', * FROM transfer('1000000003', '1000000002', 100000, 'case-3')
UNION ALL
SELECT 'More than the balance', * FROM transfer('1000000002', '1000000001', 999999999, 'case-4')
UNION ALL
SELECT 'To a frozen wallet', * FROM transfer('1000000002', '1000000003', 100000, 'case-5');
SELECT wallet_number, status, balance_kobo FROM wallets ORDER BY wallet_id;
ROLLBACK;

\echo
\echo '== Existing rows checked against the same rules =='
SELECT (SELECT count(*) FROM v_request_ledger_mismatches)                AS requests_not_matching_ledger,
       (SELECT count(*) FROM v_wallet_balance_audit WHERE difference_kobo <> 0) AS balances_not_matching_ledger,
       (SELECT net_kobo FROM v_ledger_trial_balance)                     AS ledger_net_kobo;
