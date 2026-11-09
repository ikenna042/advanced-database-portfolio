-- PART B: locking. Pessimistic row locks, a deadlock and how lock ordering avoids
-- it, optimistic locking with a version column, and SKIP LOCKED for a work queue.
-- Alpha is 1000000001 (wallet_id 2), Bravo is 1000000002 (wallet_id 3).
CREATE VIEW pg_temp.balances AS
SELECT wallet_number, balance_kobo, version FROM wallets
 WHERE wallet_number IN ('1000000001', '1000000002', '2000000001') ORDER BY wallet_number;

-- Session A waits longer than B before checking for deadlocks (default 1s), so B is
-- always the one PostgreSQL chooses to abort. This makes the output repeatable.
SET deadlock_timeout = '5s';

\echo
\echo '=== B4.1  Deadlock: two transfers in opposite directions, locking in request order ==='
\echo 'Naive code locks the source wallet first, then the destination.'
BEGIN;
\echo '[A] Alpha -> Bravo: locks Alpha'
SELECT wallet_number FROM wallets WHERE wallet_number = '1000000001' FOR UPDATE;
\echo '[B] Bravo -> Alpha: locks Bravo'
SELECT pg_temp.b('BEGIN');
SELECT pg_temp.b_value($$SELECT wallet_number::text FROM wallets WHERE wallet_number = '1000000002' FOR UPDATE$$) AS b_locked;
\echo '[B] now wants Alpha, which A holds, so B waits'
SELECT pg_temp.b_start($$SELECT wallet_number::text FROM wallets WHERE wallet_number = '1000000001' FOR UPDATE$$);
SELECT * FROM pg_temp.session_b;
\echo '[A] now wants Bravo, which B holds. Each waits for the other: a deadlock.'
SELECT wallet_number FROM wallets WHERE wallet_number = '1000000002' FOR UPDATE;
\echo 'PostgreSQL detected the cycle and aborted B, so A got its lock:'
SELECT pg_temp.b_finish() AS b_result;
SELECT pg_temp.b('ROLLBACK');
COMMIT;

\echo
\echo '=== B4.2  The same two transfers through transfer(), which locks the lower wallet_id first ==='
BEGIN;
\echo '[A] Alpha -> Bravo N1,000, not committed yet'
SELECT status FROM transfer('1000000001', '1000000002', 100000, 'b4-order-a');
\echo '[B] Bravo -> Alpha N1,000. It also asks for Alpha (wallet_id 2) first, so it simply queues:'
SELECT pg_temp.b_start($$SELECT status FROM transfer('1000000002', '1000000001', 100000, 'b4-order-b')$$);
SELECT * FROM pg_temp.session_b;
COMMIT;
\echo '[A] committed. B continues, and both transfers complete with no deadlock:'
SELECT pg_temp.b_finish() AS b_result;

\echo
\echo '=== B4.3  Pessimistic locking stops a double spend ==='
SELECT balance_kobo AS alpha_balance FROM wallets WHERE wallet_number = '1000000001' \gset
\echo 'Alpha has' :alpha_balance 'kobo. A sends all but N1,000 to Bravo; B tries to pay the merchant N5,000.'
BEGIN;
SELECT status FROM transfer('1000000001', '1000000002', :alpha_balance - 100000, 'b4-spend-a');
\echo '[B] reaches the FOR UPDATE on Alpha and waits'
SELECT pg_temp.b_start($$SELECT status || coalesce(': ' || failure_reason, '') FROM transfer('1000000001', '2000000001', 500000, 'b4-spend-b')$$);
SELECT * FROM pg_temp.session_b;
COMMIT;
\echo '[B] re-reads Alpha after the lock is released and sees only N1,000 left:'
SELECT pg_temp.b_finish() AS b_result;
\echo 'Without the lock, B would have checked the old balance and both transfers would have gone through.'
SELECT * FROM pg_temp.balances;

\echo
\echo '=== B4.4  Optimistic locking with the version column ==='
\echo 'Two support agents open Bravo''s wallet on screen. Each change is written only if'
\echo 'the version is still the one the agent saw. Ledger entries also increase the version.'
SELECT version AS seen_version FROM wallets WHERE wallet_number = '1000000002' \gset
SELECT wallet_number, status, version FROM wallets WHERE wallet_number = '1000000002';
SELECT set_config('kolaro.staff_id', (SELECT staff_id::TEXT FROM staff WHERE role = 'compliance'), FALSE) \g /dev/null
\echo '[A] compliance freezes the wallet after a fraud report'
UPDATE wallets SET status = 'frozen', version = version + 1
 WHERE wallet_number = '1000000002' AND version = :seen_version;
\echo '[B] support, still looking at the old screen, tries to close the wallet at the customer''s request'
SELECT pg_temp.b(format($$UPDATE wallets SET status = 'closed', version = version + 1
                          WHERE wallet_number = '1000000002' AND version = %s$$, :seen_version)) AS b_update;
\echo 'UPDATE 0: B''s version is stale, so nothing changed. B must reload and see that the wallet is frozen.'
SELECT wallet_number, status, version FROM wallets WHERE wallet_number = '1000000002';
UPDATE wallets SET status = 'active', version = version + 1 WHERE wallet_number = '1000000002';
SELECT actor_staff_id, action, entity_id, details FROM audit_log ORDER BY audit_id DESC LIMIT 2;

\echo
\echo '=== B4.5  SKIP LOCKED: two workers share a queue of pending withdrawals ==='
INSERT INTO withdrawals (wallet_id, amount_kobo, bank_code, bank_account_number)
SELECT wallet_id, n * 10000, '001', '0123456789'
  FROM wallets, generate_series(1, 4) AS n WHERE wallet_number = '1000000002';
BEGIN;
\echo '[A] claims the next two pending withdrawals'
SELECT withdrawal_id FROM withdrawals WHERE status = 'pending'
 ORDER BY withdrawal_id LIMIT 2 FOR UPDATE SKIP LOCKED;
\echo '[B] claims the next two: it skips the rows A has locked, without waiting'
SELECT pg_temp.b('BEGIN');
SELECT pg_temp.b_value($$SELECT string_agg(withdrawal_id::text, ', ') FROM (
                           SELECT withdrawal_id FROM withdrawals WHERE status = 'pending'
                            ORDER BY withdrawal_id LIMIT 2 FOR UPDATE SKIP LOCKED) AS s$$) AS b_claimed;
SELECT pg_temp.b('ROLLBACK');
\echo '[B] tries again without SKIP LOCKED, and has to wait behind A'
SELECT pg_temp.b('BEGIN');
SELECT pg_temp.b_start($$SELECT string_agg(withdrawal_id::text, ', ') FROM (
                           SELECT withdrawal_id FROM withdrawals WHERE status = 'pending'
                            ORDER BY withdrawal_id LIMIT 2 FOR UPDATE) AS s$$);
SELECT * FROM pg_temp.session_b;
ROLLBACK;
SELECT pg_temp.b_finish() AS b_claimed_after_wait;
SELECT pg_temp.b('ROLLBACK');
DELETE FROM withdrawals WHERE status = 'pending';

\echo
\echo '=== Consistency check after B4 ==='
SELECT (SELECT count(*) FROM v_wallet_balance_audit WHERE difference_kobo <> 0) AS balances_not_matching_ledger,
       (SELECT count(*) FROM v_request_ledger_mismatches) AS requests_not_matching_ledger,
       (SELECT net_kobo FROM v_ledger_trial_balance) AS ledger_net_kobo;
