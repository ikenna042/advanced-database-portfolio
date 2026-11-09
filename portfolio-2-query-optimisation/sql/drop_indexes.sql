-- Returns to the Portfolio 1 baseline, which has only key and constraint indexes.
SET search_path = wallet, public;
DROP INDEX IF EXISTS ledger_entries_wallet_time;
DROP INDEX IF EXISTS ledger_transactions_created_brin;
DROP INDEX IF EXISTS ledger_entries_created_brin;
DROP INDEX IF EXISTS transfers_failed_recent;
DROP INDEX IF EXISTS transfers_source_time;
ANALYZE;
