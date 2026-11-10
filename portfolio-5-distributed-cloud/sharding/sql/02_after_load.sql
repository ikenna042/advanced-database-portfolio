-- Runs after the bulk load: foreign keys, indexes and statistics, as in Portfolios 1 and 2.
SET search_path = wallet, public;

-- Allowed: both tables are sharded on wallet_id in the same way, so each shard can check
-- its own rows. The same applies to any foreign key into a reference table.
ALTER TABLE ledger_entries ADD FOREIGN KEY (wallet_id) REFERENCES wallets (wallet_id);
ALTER TABLE transfers ADD FOREIGN KEY (source_wallet_id) REFERENCES wallets (wallet_id);
ALTER TABLE wallets ADD FOREIGN KEY (merchant_id) REFERENCES merchants (merchant_id);

-- Portfolio 2's statement index. Citus creates it on every shard.
CREATE INDEX ledger_entries_wallet_time ON ledger_entries (wallet_id, created_at DESC) INCLUDE (amount_kobo, transaction_id);
CREATE INDEX transfers_source_time ON transfers (source_wallet_id, created_at DESC);

-- New rows continue after the loaded ids.
SELECT setval('wallets_wallet_id_seq', (SELECT max(wallet_id) FROM wallets));
SELECT setval('ledger_transactions_transaction_id_seq', (SELECT max(transaction_id) FROM ledger_transactions));
SELECT setval('ledger_entries_entry_id_seq', (SELECT max(entry_id) FROM ledger_entries));
SELECT setval('transfers_transfer_id_seq', (SELECT max(transfer_id) FROM transfers));

ANALYZE;
