-- Kolaro Wallet relational schema (PostgreSQL 16).
-- All money is stored as whole kobo in BIGINT, so there is no rounding error.
-- Secondary indexes for query performance are added and measured in Portfolio 2.

DROP SCHEMA IF EXISTS wallet CASCADE;
CREATE SCHEMA wallet;
ALTER DATABASE kolaro SET search_path = wallet, public;
SET search_path = wallet, public;

-- People and organisations -------------------------------------------------

CREATE TABLE staff (
    staff_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name  TEXT NOT NULL,
    email      TEXT NOT NULL,
    role       TEXT NOT NULL CHECK (role IN ('support', 'compliance', 'finance', 'auditor')),
    is_active  BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX staff_email_unique ON staff (lower(email));

CREATE TABLE customers (
    customer_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name     TEXT NOT NULL CHECK (length(trim(full_name)) > 0),
    email         TEXT NOT NULL CHECK (email LIKE '%_@_%'),
    phone         TEXT NOT NULL UNIQUE CHECK (phone ~ '^\+234[0-9]{10}$'),
    date_of_birth DATE NOT NULL CHECK (date_of_birth >= DATE '1900-01-01'),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'closed')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX customers_email_unique ON customers (lower(email));

CREATE TABLE merchants (
    merchant_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    business_name TEXT NOT NULL,
    rc_number     TEXT NOT NULL UNIQUE,
    category      TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'closed')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE banks (
    bank_code CHAR(3) PRIMARY KEY CHECK (bank_code ~ '^[0-9]{3}$'),
    bank_name TEXT NOT NULL UNIQUE
);

-- Know Your Customer -------------------------------------------------------

CREATE TABLE kyc_tiers (
    tier             SMALLINT PRIMARY KEY CHECK (tier BETWEEN 1 AND 3),
    daily_limit_kobo BIGINT NOT NULL CHECK (daily_limit_kobo > 0),
    max_balance_kobo BIGINT CHECK (max_balance_kobo > 0)  -- NULL means no ceiling
);

-- A document belongs to exactly one customer, however many times it is reviewed.
CREATE TABLE kyc_documents (
    document_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers (customer_id),
    document_type   TEXT NOT NULL CHECK (document_type IN ('bvn', 'nin', 'passport', 'drivers_licence')),
    document_number TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (document_type, document_number)
);

CREATE TABLE kyc_reviews (
    review_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id  BIGINT NOT NULL REFERENCES kyc_documents (document_id),
    tier         SMALLINT NOT NULL REFERENCES kyc_tiers (tier),
    status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    reviewed_by  BIGINT REFERENCES staff (staff_id),
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_at  TIMESTAMPTZ,
    CONSTRAINT kyc_review_outcome_recorded CHECK (
        (status = 'pending' AND reviewed_by IS NULL AND reviewed_at IS NULL)
        OR (status <> 'pending' AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
    )
);
-- A document can have many rejected reviews, but one open or approved review per tier.
CREATE UNIQUE INDEX kyc_reviews_one_live_per_tier ON kyc_reviews (document_id, tier)
    WHERE status IN ('pending', 'approved');

-- Wallets ------------------------------------------------------------------

-- balance_kobo is deliberate redundancy: it can be derived from ledger_entries, and
-- v_wallet_balance_audit proves the two agree. See normalisation.md.
CREATE TABLE wallets (
    wallet_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wallet_number CHAR(10) NOT NULL UNIQUE CHECK (wallet_number ~ '^[0-9]{10}$'),
    wallet_type   TEXT NOT NULL CHECK (wallet_type IN ('customer', 'merchant', 'system')),
    customer_id   BIGINT REFERENCES customers (customer_id),
    merchant_id   BIGINT REFERENCES merchants (merchant_id),
    system_code   TEXT UNIQUE,
    currency      CHAR(3) NOT NULL DEFAULT 'NGN' CHECK (currency = 'NGN'),
    balance_kobo  BIGINT NOT NULL DEFAULT 0,
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'frozen', 'closed')),
    version       BIGINT NOT NULL DEFAULT 0,  -- used for optimistic locking in Portfolio 3
    opened_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (customer_id, currency),
    UNIQUE (merchant_id, currency),
    CONSTRAINT wallet_has_exactly_one_owner CHECK (
        (wallet_type = 'customer' AND customer_id IS NOT NULL AND merchant_id IS NULL AND system_code IS NULL)
        OR (wallet_type = 'merchant' AND merchant_id IS NOT NULL AND customer_id IS NULL AND system_code IS NULL)
        OR (wallet_type = 'system' AND system_code IS NOT NULL AND customer_id IS NULL AND merchant_id IS NULL)
    ),
    -- System wallets represent money outside Kolaro, so they may go negative.
    CONSTRAINT wallet_balance_not_negative CHECK (wallet_type = 'system' OR balance_kobo >= 0)
);

-- The ledger: the permanent record of every posted money movement ----------

CREATE TABLE ledger_transactions (
    transaction_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_type       TEXT NOT NULL CHECK (txn_type IN ('deposit', 'withdrawal', 'transfer', 'reversal')),
    narration      TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Negative amount_kobo means money left the wallet, positive means it arrived.
CREATE TABLE ledger_entries (
    entry_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id BIGINT NOT NULL REFERENCES ledger_transactions (transaction_id),
    wallet_id      BIGINT NOT NULL REFERENCES wallets (wallet_id),
    amount_kobo    BIGINT NOT NULL CHECK (amount_kobo <> 0),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (transaction_id, wallet_id)
);

-- Operational requests: these exist before posting and may fail, so they can
-- have no ledger transaction at all ----------------------------------------

CREATE TABLE deposits (
    deposit_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wallet_id          BIGINT NOT NULL REFERENCES wallets (wallet_id),
    amount_kobo        BIGINT NOT NULL CHECK (amount_kobo > 0),
    channel            TEXT NOT NULL CHECK (channel IN ('bank_transfer', 'card', 'ussd')),
    external_reference TEXT NOT NULL UNIQUE,
    status             TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'failed')),
    transaction_id     BIGINT UNIQUE REFERENCES ledger_transactions (transaction_id),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT deposit_posted_when_completed CHECK ((status = 'completed') = (transaction_id IS NOT NULL))
);

CREATE TABLE withdrawals (
    withdrawal_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wallet_id           BIGINT NOT NULL REFERENCES wallets (wallet_id),
    amount_kobo         BIGINT NOT NULL CHECK (amount_kobo > 0),
    bank_code           CHAR(3) NOT NULL REFERENCES banks (bank_code),
    bank_account_number CHAR(10) NOT NULL CHECK (bank_account_number ~ '^[0-9]{10}$'),
    status              TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'failed')),
    transaction_id      BIGINT UNIQUE REFERENCES ledger_transactions (transaction_id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT withdrawal_posted_when_completed CHECK ((status = 'completed') = (transaction_id IS NOT NULL))
);

CREATE TABLE transfers (
    transfer_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_wallet_id      BIGINT NOT NULL REFERENCES wallets (wallet_id),
    destination_wallet_id BIGINT NOT NULL REFERENCES wallets (wallet_id),
    amount_kobo           BIGINT NOT NULL CHECK (amount_kobo > 0),
    status                TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'completed', 'failed', 'reversed')),
    failure_reason        TEXT,
    transaction_id        BIGINT UNIQUE REFERENCES ledger_transactions (transaction_id),
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT transfer_not_to_self CHECK (source_wallet_id <> destination_wallet_id),
    CONSTRAINT transfer_posted_when_completed
        CHECK ((status IN ('completed', 'reversed')) = (transaction_id IS NOT NULL)),
    CONSTRAINT transfer_failure_has_reason CHECK ((status = 'failed') = (failure_reason IS NOT NULL))
);

CREATE TABLE reversals (
    reversal_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    original_transaction_id BIGINT NOT NULL UNIQUE REFERENCES ledger_transactions (transaction_id),
    reversal_transaction_id BIGINT NOT NULL UNIQUE REFERENCES ledger_transactions (transaction_id),
    reason                  TEXT NOT NULL,
    requested_by            BIGINT NOT NULL REFERENCES staff (staff_id),
    approved_by             BIGINT NOT NULL REFERENCES staff (staff_id),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT reversal_is_a_different_transaction CHECK (original_transaction_id <> reversal_transaction_id),
    CONSTRAINT reversal_needs_two_people CHECK (requested_by <> approved_by)
);

CREATE TABLE idempotency_keys (
    customer_id     BIGINT NOT NULL REFERENCES customers (customer_id),
    idempotency_key TEXT NOT NULL,
    request_hash    TEXT NOT NULL,
    transaction_id  BIGINT REFERENCES ledger_transactions (transaction_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id, idempotency_key)
);

CREATE TABLE audit_log (
    audit_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_staff_id BIGINT REFERENCES staff (staff_id),  -- NULL means the system acted
    action         TEXT NOT NULL,
    entity_type    TEXT NOT NULL,
    entity_id      BIGINT NOT NULL,
    details        JSONB NOT NULL DEFAULT '{}',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
