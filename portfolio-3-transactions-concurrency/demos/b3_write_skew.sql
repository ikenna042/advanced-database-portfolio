-- PART B: write skew, the anomaly REPEATABLE READ still allows.
-- Business rule: at least one finance staff member must stay active, because every
-- reversal needs finance approval (Portfolio 1, reversal_needs_two_people).
-- Two admins each deactivate a different finance officer at the same time. Each
-- checks the rule first, sees two officers, and goes ahead.

INSERT INTO staff (full_name, email, role) VALUES ('Finance Officer Two', 'finance.two@kolaro.example', 'finance');
CREATE VIEW pg_temp.finance AS
SELECT staff_id, full_name, is_active FROM staff WHERE role = 'finance' ORDER BY staff_id;
SELECT * FROM pg_temp.finance;

\echo
\echo '=== B3.1  REPEATABLE READ: both commit, and the rule is broken ==='
BEGIN ISOLATION LEVEL REPEATABLE READ;
\echo '[A] checks how many finance officers are active'
SELECT count(*) AS active_finance FROM staff WHERE role = 'finance' AND is_active;
\echo '[B] checks the same'
SELECT pg_temp.b('BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT pg_temp.b_value($$SELECT count(*)::text FROM staff WHERE role = 'finance' AND is_active$$) AS b_active_finance;
\echo '[A] deactivates Finance Lead; [B] deactivates Finance Officer Two. Different rows, so no lock conflict.'
UPDATE staff SET is_active = FALSE WHERE email = 'finance@kolaro.example';
SELECT pg_temp.b($$UPDATE staff SET is_active = FALSE WHERE email = 'finance.two@kolaro.example'$$);
COMMIT;
SELECT pg_temp.b('COMMIT') AS b_commit;
\echo 'Result: no active finance officer is left.'
SELECT * FROM pg_temp.finance;
UPDATE staff SET is_active = TRUE WHERE role = 'finance';

\echo
\echo '=== B3.2  SERIALIZABLE: PostgreSQL detects the conflict and aborts one transaction ==='
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) AS active_finance FROM staff WHERE role = 'finance' AND is_active;
SELECT pg_temp.b('BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT pg_temp.b_value($$SELECT count(*)::text FROM staff WHERE role = 'finance' AND is_active$$) AS b_active_finance;
UPDATE staff SET is_active = FALSE WHERE email = 'finance@kolaro.example';
SELECT pg_temp.b($$UPDATE staff SET is_active = FALSE WHERE email = 'finance.two@kolaro.example'$$);
\echo '[A] commits first and succeeds'
COMMIT;
\echo '[B] commits second and gets SQLSTATE 40001'
SELECT pg_temp.b('COMMIT') AS b_commit;
\echo '[B] retries from the start, as the application must. The check now sees one officer, so B stops.'
SELECT pg_temp.b('BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT pg_temp.b_value($$SELECT count(*)::text FROM staff WHERE role = 'finance' AND is_active$$) AS b_active_finance;
SELECT pg_temp.b('ROLLBACK');
SELECT * FROM pg_temp.finance;
UPDATE staff SET is_active = TRUE WHERE role = 'finance';

\echo
\echo '=== B3.3  READ COMMITTED with SELECT ... FOR UPDATE: the check itself takes locks ==='
BEGIN;
\echo '[A] locks the active finance officers while it checks them'
SELECT staff_id, full_name FROM staff WHERE role = 'finance' AND is_active ORDER BY staff_id FOR UPDATE;
\echo '[B] runs the same locking check, and has to wait'
SELECT pg_temp.b('BEGIN');
SELECT pg_temp.b_start($$SELECT count(*)::text FROM (SELECT 1 FROM staff WHERE role = 'finance' AND is_active FOR UPDATE) AS s$$);
SELECT * FROM pg_temp.session_b;
\echo '[A] deactivates Finance Lead and commits'
UPDATE staff SET is_active = FALSE WHERE email = 'finance@kolaro.example';
COMMIT;
\echo '[B] now gets its answer, re-checked against the committed rows: only one officer is active, so B stops'
SELECT pg_temp.b_finish() AS b_active_finance;
SELECT pg_temp.b('ROLLBACK');
SELECT * FROM pg_temp.finance;
UPDATE staff SET is_active = TRUE WHERE role = 'finance';
