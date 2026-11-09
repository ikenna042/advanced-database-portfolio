-- E3. Would monthly range partitioning help ledger_entries?
-- A partitioned copy is built, compared with the real table, then dropped.
SET search_path = wallet, public;
SET work_mem = '64MB';
\pset pager off

DROP TABLE IF EXISTS e3_entries;
CREATE TABLE e3_entries (
    entry_id       BIGINT NOT NULL,
    transaction_id BIGINT NOT NULL,
    wallet_id      BIGINT NOT NULL,
    amount_kobo    BIGINT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL
) PARTITION BY RANGE (created_at);

DO $$
DECLARE
    m DATE;
BEGIN
    FOR m IN SELECT generate_series(DATE '2025-06-01', DATE '2026-12-01', INTERVAL '1 month')::DATE LOOP
        EXECUTE format('CREATE TABLE e3_entries_%s PARTITION OF e3_entries FOR VALUES FROM (%L) TO (%L)',
                       to_char(m, 'YYYY_MM'), m, (m + INTERVAL '1 month')::DATE);
    END LOOP;
END $$;
CREATE TABLE e3_entries_default PARTITION OF e3_entries DEFAULT;

\timing on
INSERT INTO e3_entries SELECT entry_id, transaction_id, wallet_id, amount_kobo, created_at FROM ledger_entries;
\timing off
CREATE INDEX ON e3_entries (wallet_id, created_at);
ANALYZE e3_entries;

\echo '== Rows per partition (first and last few) =='
SELECT tableoid::regclass AS partition, count(*) AS row_count
  FROM e3_entries GROUP BY 1 ORDER BY 1;

\echo '== October totals on the plain table (uses the BRIN index) =='
\o /dev/null
SELECT created_at::DATE, sum(amount_kobo) FROM ledger_entries
 WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01' AND amount_kobo > 0 GROUP BY 1;
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT created_at::DATE, sum(amount_kobo) FROM ledger_entries
 WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01' AND amount_kobo > 0 GROUP BY 1;

\echo '== October totals on the partitioned copy (partition pruning) =='
\o /dev/null
SELECT created_at::DATE, sum(amount_kobo) FROM e3_entries
 WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01' AND amount_kobo > 0 GROUP BY 1;
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT created_at::DATE, sum(amount_kobo) FROM e3_entries
 WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01' AND amount_kobo > 0 GROUP BY 1;

\echo '== A query that does not filter on the partition key must visit every partition =='
EXPLAIN (COSTS OFF)
SELECT count(*) FROM e3_entries WHERE wallet_id = 9;

\echo '== Cost: a primary key on entry_id alone is not allowed =='
\set ON_ERROR_STOP 0
ALTER TABLE e3_entries ADD PRIMARY KEY (entry_id);
ALTER TABLE e3_entries ADD UNIQUE (transaction_id, wallet_id);
\set ON_ERROR_STOP 1

\echo '== Dropping old data: detach a partition instead of a large DELETE =='
\timing on
ALTER TABLE e3_entries DETACH PARTITION e3_entries_2025_11;
\timing off

DROP TABLE e3_entries, e3_entries_2025_11;
