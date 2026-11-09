-- PART B: what each isolation level lets a transaction see while another session
-- commits changes. Alpha is 1000000001, Bravo is 1000000002.
CREATE VIEW pg_temp.alpha AS
SELECT balance_kobo FROM wallets WHERE wallet_number = '1000000001';

\echo
\echo '=== B2.1  Dirty read: not possible in PostgreSQL, even at READ UNCOMMITTED ==='
\echo '[A] begins a N1,000 transfer from Alpha and does not commit'
BEGIN;
SELECT status FROM transfer('1000000001', '1000000002', 100000, 'b2-dirty');
SELECT * FROM pg_temp.alpha;
\echo '[B] reads Alpha at READ UNCOMMITTED'
SELECT pg_temp.b('BEGIN ISOLATION LEVEL READ UNCOMMITTED');
SELECT pg_temp.b_value($$SELECT balance_kobo::text FROM wallets WHERE wallet_number = '1000000001'$$) AS b_sees;
SELECT pg_temp.b('COMMIT');
\echo 'B saw the committed balance, not A''s uncommitted one. PostgreSQL runs READ UNCOMMITTED as READ COMMITTED.'
ROLLBACK;

\echo
\echo '=== B2.2  Non-repeatable read at READ COMMITTED ==='
BEGIN ISOLATION LEVEL READ COMMITTED;
\echo '[A] reads Alpha''s balance'
SELECT * FROM pg_temp.alpha;
\echo '[B] sends N1,000 from Alpha and commits'
SELECT pg_temp.b_value($$SELECT status FROM transfer('1000000001', '1000000002', 100000, 'b2-nonrepeatable-rc')$$) AS b_transfer;
\echo '[A] reads again in the same transaction, and gets a different value'
SELECT * FROM pg_temp.alpha;
COMMIT;

\echo
\echo '=== B2.3  REPEATABLE READ prevents it ==='
BEGIN ISOLATION LEVEL REPEATABLE READ;
\echo '[A] reads Alpha''s balance. Its snapshot is fixed at this first query.'
SELECT * FROM pg_temp.alpha;
\echo '[B] sends N1,000 from Alpha and commits'
SELECT pg_temp.b_value($$SELECT status FROM transfer('1000000001', '1000000002', 100000, 'b2-nonrepeatable-rr')$$) AS b_transfer;
\echo '[A] reads again: same value as before'
SELECT * FROM pg_temp.alpha;
COMMIT;
\echo '[A] after COMMIT, a new transaction sees B''s change'
SELECT * FROM pg_temp.alpha;

\echo
\echo '=== B2.4  Phantom read at READ COMMITTED ==='
\echo 'A compliance report counts Alpha''s completed transfers twice in one transaction.'
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT count(*) AS alpha_transfers FROM transfers t JOIN wallets w ON w.wallet_id = t.source_wallet_id
 WHERE w.wallet_number = '1000000001' AND t.status = 'completed';
\echo '[B] inserts a new transfer from Alpha and commits'
SELECT pg_temp.b_value($$SELECT status FROM transfer('1000000001', '1000000002', 100000, 'b2-phantom-rc')$$) AS b_transfer;
\echo '[A] counts again: a new row has appeared'
SELECT count(*) AS alpha_transfers FROM transfers t JOIN wallets w ON w.wallet_id = t.source_wallet_id
 WHERE w.wallet_number = '1000000001' AND t.status = 'completed';
COMMIT;

\echo
\echo '=== B2.5  REPEATABLE READ prevents phantoms too in PostgreSQL ==='
\echo '(The SQL standard allows phantoms at this level, but PostgreSQL''s snapshot does not.)'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) AS alpha_transfers FROM transfers t JOIN wallets w ON w.wallet_id = t.source_wallet_id
 WHERE w.wallet_number = '1000000001' AND t.status = 'completed';
\echo '[B] inserts another transfer from Alpha and commits'
SELECT pg_temp.b_value($$SELECT status FROM transfer('1000000001', '1000000002', 100000, 'b2-phantom-rr')$$) AS b_transfer;
SELECT count(*) AS alpha_transfers FROM transfers t JOIN wallets w ON w.wallet_id = t.source_wallet_id
 WHERE w.wallet_number = '1000000001' AND t.status = 'completed';
COMMIT;

\echo
\echo '=== B2.6  The cost of REPEATABLE READ: writers must retry ==='
BEGIN ISOLATION LEVEL REPEATABLE READ;
\echo '[A] reads Alpha''s balance, which fixes its snapshot'
SELECT * FROM pg_temp.alpha;
\echo '[B] sends N1,000 from Alpha and commits'
SELECT pg_temp.b_value($$SELECT status FROM transfer('1000000001', '1000000002', 100000, 'b2-retry-b')$$) AS b_transfer;
\echo '[A] now tries its own transfer from Alpha. transfer() locks Alpha''s row, which changed'
\echo '    after A''s snapshot, so PostgreSQL raises SQLSTATE 40001 instead of using stale data:'
\set ON_ERROR_STOP off
SELECT status FROM transfer('1000000001', '1000000002', 100000, 'b2-retry-a');
\set ON_ERROR_STOP on
ROLLBACK;
\echo '[A] retries the whole transaction with a new snapshot, and it succeeds'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT status FROM transfer('1000000001', '1000000002', 100000, 'b2-retry-a');
COMMIT;

\echo
\echo '=== Consistency check after B2 ==='
SELECT (SELECT count(*) FROM v_wallet_balance_audit WHERE difference_kobo <> 0) AS balances_not_matching_ledger,
       (SELECT net_kobo FROM v_ledger_trial_balance) AS ledger_net_kobo;
