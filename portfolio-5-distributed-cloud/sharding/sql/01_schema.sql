-- The Kolaro ledger tables on a Citus cluster. Columns match Portfolio 1; keys and
-- constraints are adapted to what a sharded database can enforce. Every change from
-- Portfolio 1 is marked "Sharding:".
CREATE SCHEMA wallet;
SET search_path = wallet, public;

-- Small and read by many queries: copied in full to every node (a reference table).
CREATE TABLE merchants (
    merchant_id   BIGINT PRIMARY KEY,
    business_name TEXT NOT NULL,
    rc_number     TEXT NOT NULL UNIQUE,
    category      TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'closed')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Sharding: distributed by customer_id. UNIQUE (phone) and the unique index on lower(email)
-- are dropped: a distributed table can only enforce uniqueness that includes the shard key,
-- because each shard checks its own rows only. s1_cluster.txt shows Citus refusing it.
CREATE TABLE customers (
    customer_id   BIGINT PRIMARY KEY,
    full_name     TEXT NOT NULL CHECK (length(trim(full_name)) > 0),
    email         TEXT NOT NULL CHECK (email LIKE '%_@_%'),
    phone         TEXT NOT NULL CHECK (phone ~ '^\+234[0-9]{10}$'),
    date_of_birth DATE NOT NULL CHECK (date_of_birth >= DATE '1900-01-01'),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'closed')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Sharding: distributed by wallet_id. UNIQUE (wallet_number) and UNIQUE (customer_id,
-- currency) are dropped for the same reason, and the foreign key to customers too, because
-- a wallet and its customer are usually on different shards.
CREATE TABLE wallets (
    wallet_id     BIGSERIAL PRIMARY KEY,
    wallet_number CHAR(10) NOT NULL CHECK (wallet_number ~ '^[0-9]{10}$'),
    wallet_type   TEXT NOT NULL CHECK (wallet_type IN ('customer', 'merchant', 'system')),
    customer_id   BIGINT,
    merchant_id   BIGINT,
    system_code   TEXT,
    currency      CHAR(3) NOT NULL DEFAULT 'NGN' CHECK (currency = 'NGN'),
    balance_kobo  BIGINT NOT NULL DEFAULT 0,
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'frozen', 'closed')),
    version       BIGINT NOT NULL DEFAULT 0,
    opened_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT wallet_has_exactly_one_owner CHECK (
        (wallet_type = 'customer' AND customer_id IS NOT NULL AND merchant_id IS NULL AND system_code IS NULL)
        OR (wallet_type = 'merchant' AND merchant_id IS NOT NULL AND customer_id IS NULL AND system_code IS NULL)
        OR (wallet_type = 'system' AND system_code IS NOT NULL AND customer_id IS NULL AND merchant_id IS NULL)
    ),
    CONSTRAINT wallet_balance_not_negative CHECK (wallet_type = 'system' OR balance_kobo >= 0)
);

-- Sharding: distributed by transaction_id, in its own group. Its two entries live with
-- their wallets, so a transaction and its entries are generally on different shards.
CREATE TABLE ledger_transactions (
    transaction_id BIGSERIAL PRIMARY KEY,
    txn_type       TEXT NOT NULL CHECK (txn_type IN ('deposit', 'withdrawal', 'transfer', 'reversal')),
    narration      TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Sharding: distributed by wallet_id and co-located with wallets, so a wallet and all its
-- entries are on the same shard. The primary key must include the shard key. The foreign
-- key to ledger_transactions is dropped (different shard key); the one to wallets is kept.
CREATE TABLE ledger_entries (
    entry_id       BIGSERIAL,
    transaction_id BIGINT NOT NULL,
    wallet_id      BIGINT NOT NULL,
    amount_kobo    BIGINT NOT NULL CHECK (amount_kobo <> 0),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (wallet_id, entry_id),
    UNIQUE (transaction_id, wallet_id)
);

-- Sharding: distributed by source_wallet_id and co-located with wallets. UNIQUE
-- (transaction_id) and the foreign keys to the destination wallet and ledger_transactions
-- are dropped.
CREATE TABLE transfers (
    transfer_id           BIGSERIAL,
    source_wallet_id      BIGINT NOT NULL,
    destination_wallet_id BIGINT NOT NULL,
    amount_kobo           BIGINT NOT NULL CHECK (amount_kobo > 0),
    status                TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'completed', 'failed', 'reversed')),
    failure_reason        TEXT,
    transaction_id        BIGINT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source_wallet_id, transfer_id),
    CONSTRAINT transfer_not_to_self CHECK (source_wallet_id <> destination_wallet_id),
    CONSTRAINT transfer_posted_when_completed
        CHECK ((status IN ('completed', 'reversed')) = (transaction_id IS NOT NULL)),
    CONSTRAINT transfer_failure_has_reason CHECK ((status = 'failed') = (failure_reason IS NOT NULL))
);

SELECT create_reference_table('merchants');
SELECT create_distributed_table('customers', 'customer_id', colocate_with => 'none');
SELECT create_distributed_table('wallets', 'wallet_id', colocate_with => 'none');
SELECT create_distributed_table('ledger_entries', 'wallet_id', colocate_with => 'wallets');
SELECT create_distributed_table('transfers', 'source_wallet_id', colocate_with => 'wallets');
SELECT create_distributed_table('ledger_transactions', 'transaction_id', colocate_with => 'none');
