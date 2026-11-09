-- Prepended to every demo by run.sh.
-- The psql connection running the demo is SESSION A.
-- SESSION B is a second, independent connection opened with dblink. Because both
-- sessions are driven from one script, their statements interleave in a fixed,
-- repeatable order, which makes the concurrency effects reproducible.
SET search_path = wallet, public;
SET client_min_messages = warning;   -- errors from B are returned as text instead
\pset pager off
\pset footer off

SELECT dblink_connect('b', 'dbname=kolaro user=kolaro application_name=session_b') \g /dev/null

-- Runs one statement in session B and returns its status, or the error it raised.
CREATE FUNCTION pg_temp.b(p_sql TEXT) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT := dblink_exec('b', p_sql, false);
BEGIN
    IF v_status = 'ERROR' THEN
        RETURN dblink_error_message('b');
    END IF;
    RETURN v_status;
END $$;

-- Runs a query in session B that returns one text value.
CREATE FUNCTION pg_temp.b_value(p_sql TEXT) RETURNS TEXT
LANGUAGE sql AS $$ SELECT v FROM dblink('b', p_sql) AS t(v TEXT) $$;

-- Starts a statement in session B without waiting for it to finish.
CREATE FUNCTION pg_temp.b_start(p_sql TEXT) RETURNS TEXT
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM dblink_send_query('b', p_sql);
    PERFORM pg_sleep(0.5);   -- give it time to reach the database and block, if it is going to
    RETURN 'started';
END $$;

-- Waits for the statement started with b_start and returns its result or error.
CREATE FUNCTION pg_temp.b_finish() RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_result TEXT;
BEGIN
    SELECT v INTO v_result FROM dblink_get_result('b', false) AS t(v TEXT);
    IF NOT FOUND THEN
        v_result := dblink_error_message('b');
    END IF;
    PERFORM * FROM dblink_get_result('b', false) AS t(v TEXT);  -- clear the connection
    RETURN v_result;
END $$;

-- What session B is doing right now, as seen by the server.
CREATE VIEW pg_temp.session_b AS
SELECT state, wait_event_type, wait_event, left(regexp_replace(query, '\s+', ' ', 'g'), 60) AS query
  FROM pg_stat_activity
 WHERE application_name = 'session_b';

\set ECHO queries
