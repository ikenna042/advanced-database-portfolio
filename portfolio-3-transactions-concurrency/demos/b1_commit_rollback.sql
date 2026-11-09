-- PART B: commit, rollback, savepoints and atomicity, using the transfer procedure.
-- Alpha is 1000000001, Bravo is 1000000002 and the merchant is 2000000001.
CREATE VIEW pg_temp.balances AS
SELECT wallet_number, balance_kobo FROM wallets
 WHERE wallet_number IN ('1000000001', '1000000002', '2000000001') ORDER BY wallet_number;

\echo
\echo '=== B1.1  COMMIT makes a transfer permanent ==='
SELECT * FROM pg_temp.balances;
BEGIN;
SELECT * FROM transfer('1000000001', '1000000002', 500000, 'b1-commit', 'Commit demo');
COMMIT;
SELECT * FROM pg_temp.balances;

\echo
\echo '=== B1.2  ROLLBACK undoes everything the transaction did ==='
BEGIN;
SELECT * FROM transfer('1000000001', '1000000002', 300000, 'b1-rollback', 'Rollback demo');
\echo 'Inside the transaction, A sees its own change:'
SELECT * FROM pg_temp.balances;
\echo '[B] at the same moment sees only committed data:'
SELECT pg_temp.b_value($$SELECT balance_kobo::text FROM wallets WHERE wallet_number = '1000000001'$$) AS b_sees_alpha;
ROLLBACK;
\echo 'After ROLLBACK: balances, ledger, transfer row and idempotency key are all gone.'
SELECT * FROM pg_temp.balances;
SELECT (SELECT count(*) FROM idempotency_keys WHERE idempotency_key = 'b1-rollback') AS keys_left,
       (SELECT count(*) FROM ledger_transactions WHERE narration = 'Rollback demo') AS ledger_rows_left;

\echo
\echo '=== B1.3  A SAVEPOINT undoes part of a transaction ==='
BEGIN;
SELECT * FROM transfer('1000000001', '1000000002', 200000, 'b1-savepoint-1', 'Savepoint demo, kept');
SAVEPOINT before_fix;
\echo 'A support script then tries to edit a balance directly. The guard trigger rejects it,'
\echo 'which puts the whole transaction into an aborted state:'
\set ON_ERROR_STOP off
UPDATE wallets SET balance_kobo = balance_kobo + 100000 WHERE wallet_number = '1000000002';
SELECT 'any statement now fails';
\set ON_ERROR_STOP on
\echo 'Rolling back to the savepoint keeps the first transfer and clears the error:'
ROLLBACK TO SAVEPOINT before_fix;
SELECT * FROM transfer('1000000001', '2000000001', 100000, 'b1-savepoint-2', 'Savepoint demo, second');
COMMIT;
SELECT transfer_id, amount_kobo, status, l.narration
  FROM transfers t JOIN ledger_transactions l USING (transaction_id)
 WHERE l.narration LIKE 'Savepoint demo%' ORDER BY transfer_id;
SELECT * FROM pg_temp.balances;

\echo
\echo '=== B1.4  Atomicity: a check that fails at COMMIT undoes the whole transaction ==='
BEGIN;
SELECT * FROM transfer('1000000001', '1000000002', 100000, 'b1-atomic', 'Atomicity demo');
\echo 'In the same transaction, a faulty batch job posts a ledger transaction with only one entry.'
INSERT INTO ledger_transactions (txn_type, narration) VALUES ('deposit', 'Faulty batch') RETURNING transaction_id \gset
INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
SELECT :transaction_id, wallet_id, 999 FROM wallets WHERE wallet_number = '1000000002';
\echo 'Every statement succeeded. The balanced-ledger check is deferred until COMMIT:'
\set ON_ERROR_STOP off
COMMIT;
\set ON_ERROR_STOP on
\echo 'The good transfer was rolled back along with the faulty entry:'
SELECT (SELECT count(*) FROM idempotency_keys WHERE idempotency_key = 'b1-atomic') AS atomic_keys_left,
       (SELECT count(*) FROM ledger_transactions WHERE narration IN ('Atomicity demo', 'Faulty batch')) AS ledger_rows_left;
SELECT * FROM pg_temp.balances;

\echo
\echo '=== Consistency check after B1 ==='
SELECT (SELECT count(*) FROM v_wallet_balance_audit WHERE difference_kobo <> 0) AS balances_not_matching_ledger,
       (SELECT net_kobo FROM v_ledger_trial_balance) AS ledger_net_kobo;
