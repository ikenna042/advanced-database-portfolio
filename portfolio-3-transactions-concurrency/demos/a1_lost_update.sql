-- PART A, on the plain Portfolio 1 schema: the lost update problem and three ways
-- PostgreSQL behaves. Alpha is wallet 1000000001 and Bravo is 1000000002.
-- Each scenario debits Alpha twice, once from each session, and credits Bravo.

\echo
\echo '=== A1.1  Lost update under READ COMMITTED (the default) ==='
\echo 'Each session reads Alpha''s balance, then writes back (what it read - amount).'
SELECT wallet_number, stored_kobo, ledger_kobo, difference_kobo
  FROM v_wallet_balance_audit WHERE wallet_number = '1000000001';

\echo '[A] begins and reads Alpha''s balance'
BEGIN;
SELECT balance_kobo AS a_read FROM wallets WHERE wallet_number = '1000000001' \gset
\echo '    A read' :a_read
\echo '[B] begins and reads the same balance'
SELECT pg_temp.b('BEGIN');
SELECT pg_temp.b_value($$SELECT balance_kobo::text FROM wallets WHERE wallet_number = '1000000001'$$) AS b_read \gset
\echo '    B read' :b_read
\echo '[A] sends N1,000 to Bravo: posts the ledger entries, writes the balance it computed, commits'
SELECT post_entries('1000000001', '1000000002', 100000) AS a_txn;
UPDATE wallets SET balance_kobo = :a_read - 100000 WHERE wallet_number = '1000000001';
UPDATE wallets SET balance_kobo = balance_kobo + 100000 WHERE wallet_number = '1000000002';
COMMIT;
\echo '[B] sends N2,000 the same way, using the balance it read before A committed'
SELECT pg_temp.b_value($$SELECT post_entries('1000000001', '1000000002', 200000)::text$$) AS b_txn;
SELECT pg_temp.b(format($$UPDATE wallets SET balance_kobo = %s WHERE wallet_number = '1000000001'$$, :b_read - 200000));
SELECT pg_temp.b($$UPDATE wallets SET balance_kobo = balance_kobo + 200000 WHERE wallet_number = '1000000002'$$);
SELECT pg_temp.b('COMMIT');
\echo 'Result: the ledger shows both debits, but the stored balance only reflects B''s.'
\echo 'A''s N1,000 debit was overwritten, so Alpha''s stored balance is N1,000 too high.'
SELECT wallet_number, stored_kobo, ledger_kobo, difference_kobo
  FROM v_wallet_balance_audit WHERE wallet_number = '1000000001';

\echo
\echo '=== A1.2  The same code under REPEATABLE READ: PostgreSQL detects the conflict ==='
\echo '[A] begins and reads'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance_kobo AS a_read FROM wallets WHERE wallet_number = '1000000001' \gset
\echo '[B] begins and reads'
SELECT pg_temp.b('BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT pg_temp.b_value($$SELECT balance_kobo::text FROM wallets WHERE wallet_number = '1000000001'$$) AS b_read \gset
\echo '[A] debits N1,000 and commits'
SELECT post_entries('1000000001', '1000000002', 100000) AS a_txn;
UPDATE wallets SET balance_kobo = :a_read - 100000 WHERE wallet_number = '1000000001';
UPDATE wallets SET balance_kobo = balance_kobo + 100000 WHERE wallet_number = '1000000002';
COMMIT;
\echo '[B] tries to update a row changed since its snapshot was taken'
SELECT pg_temp.b_value($$SELECT post_entries('1000000001', '1000000002', 200000)::text$$) AS b_txn;
SELECT pg_temp.b(format($$UPDATE wallets SET balance_kobo = %s WHERE wallet_number = '1000000001'$$, :b_read - 200000)) AS b_update;
SELECT pg_temp.b('ROLLBACK');
\echo '[B] retries the whole transaction, as an application must on SQLSTATE 40001'
SELECT pg_temp.b('BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT pg_temp.b_value($$SELECT balance_kobo::text FROM wallets WHERE wallet_number = '1000000001'$$) AS b_read \gset
\echo '    B now reads' :b_read
SELECT pg_temp.b_value($$SELECT post_entries('1000000001', '1000000002', 200000)::text$$) AS b_txn;
SELECT pg_temp.b(format($$UPDATE wallets SET balance_kobo = %s WHERE wallet_number = '1000000001'$$, :b_read - 200000));
SELECT pg_temp.b($$UPDATE wallets SET balance_kobo = balance_kobo + 200000 WHERE wallet_number = '1000000002'$$);
SELECT pg_temp.b('COMMIT');
\echo 'Result: the difference is still the N1,000 lost in A1.1. Nothing new was lost.'
SELECT wallet_number, stored_kobo, ledger_kobo, difference_kobo
  FROM v_wallet_balance_audit WHERE wallet_number = '1000000001';

\echo
\echo '=== A1.3  READ COMMITTED with relative updates and a row lock ==='
\echo 'Each session writes balance_kobo = balance_kobo - amount, so it never relies on an earlier read.'
\echo '[A] begins and debits N1,000, without committing yet'
BEGIN;
SELECT post_entries('1000000001', '1000000002', 100000) AS a_txn;
UPDATE wallets SET balance_kobo = balance_kobo - 100000 WHERE wallet_number = '1000000001';
UPDATE wallets SET balance_kobo = balance_kobo + 100000 WHERE wallet_number = '1000000002';
\echo '[B] begins and tries to debit N2,000: it has to wait for A''s row lock'
SELECT pg_temp.b('BEGIN');
SELECT pg_temp.b_value($$SELECT post_entries('1000000001', '1000000002', 200000)::text$$) AS b_txn;
SELECT pg_temp.b_start($$UPDATE wallets SET balance_kobo = balance_kobo - 200000 WHERE wallet_number = '1000000001'$$);
SELECT * FROM pg_temp.session_b;
\echo '[A] commits, which releases the lock'
COMMIT;
\echo '[B] re-reads the committed row and applies its update to it'
SELECT pg_temp.b_finish() AS b_update;
SELECT pg_temp.b($$UPDATE wallets SET balance_kobo = balance_kobo + 200000 WHERE wallet_number = '1000000002'$$);
SELECT pg_temp.b('COMMIT');
\echo 'Result: still only the original N1,000 difference. Both debits were applied.'
SELECT wallet_number, stored_kobo, ledger_kobo, difference_kobo
  FROM v_wallet_balance_audit WHERE wallet_number = '1000000001';
