-- Secondary indexes chosen from the baseline execution plans. Each names the query it serves.
SET search_path = wallet, public;
SET maintenance_work_mem = '512MB';
\timing on

-- Q1, Q4, Q5: a wallet's entries in time order. INCLUDE adds the columns the queries
-- read, so PostgreSQL can often answer from the index alone (an index-only scan).
CREATE INDEX ledger_entries_wallet_time
    ON ledger_entries (wallet_id, created_at DESC, entry_id DESC)
    INCLUDE (amount_kobo, transaction_id);

-- Q3: date ranges on the ledger. The table is inserted in time order, so a BRIN index,
-- which stores only the min and max date of each block range, is tiny but effective.
CREATE INDEX ledger_transactions_created_brin
    ON ledger_transactions USING brin (created_at);

-- Q3b, Q8: the same for ledger entries, which are also inserted in time order.
CREATE INDEX ledger_entries_created_brin
    ON ledger_entries USING brin (created_at);

-- Q6: only about 2% of transfers fail, so a partial index holds just those rows.
CREATE INDEX transfers_failed_recent
    ON transfers (created_at DESC)
    WHERE status = 'failed';

-- Q7: each hop looks up transfers out of one wallet within a time window.
CREATE INDEX transfers_source_time
    ON transfers (source_wallet_id, created_at)
    WHERE status = 'completed';

\timing off
ANALYZE;

SELECT indexrelid::regclass AS index_name,
       indrelid::regclass   AS table_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
  FROM pg_index
 WHERE indexrelid::regclass::TEXT IN ('ledger_entries_wallet_time', 'ledger_transactions_created_brin',
                                      'ledger_entries_created_brin', 'transfers_failed_recent', 'transfers_source_time')
 ORDER BY pg_relation_size(indexrelid) DESC;
