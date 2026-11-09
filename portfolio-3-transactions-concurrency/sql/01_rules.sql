-- Portfolio 3 rules. These close three gaps listed in Portfolio 1's "Known limitations":
--   1. A frozen or closed wallet can't send money.
--   2. A wallet's stored balance always equals the sum of its ledger entries.
--   3. A deposit, withdrawal or transfer request's amount matches its ledger entries.
-- Applied on top of the Portfolio 1 schema and sample data.
SET search_path = wallet, public;

-- The idempotency table also remembers which transfer a key produced, so a retried
-- request that failed the first time gets the same failure back.
ALTER TABLE idempotency_keys
    ADD COLUMN transfer_id BIGINT UNIQUE REFERENCES transfers (transfer_id);

-- Rules 1 and 2: every new ledger entry updates its wallet's balance, inside the
-- same transaction. Before it does, it locks the wallet row and checks its status.
CREATE FUNCTION ledger_apply_entry() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
    v_type   TEXT;
BEGIN
    -- FOR UPDATE waits for any other transaction changing this wallet, then reads
    -- its latest committed status.
    SELECT status INTO v_status FROM wallets WHERE wallet_id = NEW.wallet_id FOR UPDATE;

    IF v_status = 'closed' OR (v_status = 'frozen' AND NEW.amount_kobo < 0) THEN
        -- Finance must still be able to reverse money out of a frozen wallet.
        SELECT txn_type INTO v_type FROM ledger_transactions WHERE transaction_id = NEW.transaction_id;
        IF v_type <> 'reversal' THEN
            RAISE EXCEPTION 'wallet % is %, so this entry of % kobo is not allowed',
                NEW.wallet_id, v_status, NEW.amount_kobo
                USING ERRCODE = 'check_violation', CONSTRAINT = 'wallet_must_be_active';
        END IF;
    END IF;

    -- A relative update (balance + amount), never an absolute value read earlier.
    UPDATE wallets
       SET balance_kobo = balance_kobo + NEW.amount_kobo,
           version      = version + 1
     WHERE wallet_id = NEW.wallet_id;
    RETURN NULL;
END $$;

CREATE TRIGGER ledger_entries_apply
    AFTER INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION ledger_apply_entry();

-- Rule 2, continued: a wallet starts at zero, and its balance can change only
-- through the trigger above. pg_trigger_depth() is 1 for a direct UPDATE and 2
-- when the UPDATE comes from ledger_apply_entry().
CREATE FUNCTION wallet_guard_balance() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.balance_kobo <> 0 THEN
        RAISE EXCEPTION 'a new wallet must start with a zero balance'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'wallet_starts_at_zero';
    END IF;
    IF TG_OP = 'UPDATE' AND pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION 'the balance of wallet % can only change through a ledger entry', OLD.wallet_id
            USING ERRCODE = 'restrict_violation', CONSTRAINT = 'balance_changes_through_ledger';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER wallets_guard_balance_insert
    BEFORE INSERT ON wallets
    FOR EACH ROW EXECUTE FUNCTION wallet_guard_balance();

CREATE TRIGGER wallets_guard_balance_update
    BEFORE UPDATE OF balance_kobo ON wallets
    FOR EACH ROW WHEN (OLD.balance_kobo IS DISTINCT FROM NEW.balance_kobo)
    EXECUTE FUNCTION wallet_guard_balance();

-- Rule 3: describes what is wrong with a request's ledger posting, or returns NULL
-- if it matches. Used by the triggers below and by v_request_ledger_mismatches.
-- p_kind is the table name and p_row is the request row as JSON.
CREATE FUNCTION request_ledger_problem(p_kind TEXT, p_row JSONB) RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_txn      BIGINT := (p_row ->> 'transaction_id')::BIGINT;
    v_amount   BIGINT := (p_row ->> 'amount_kobo')::BIGINT;
    v_expected TEXT;
    v_debit    BIGINT;   -- wallet that must lose v_amount, if known
    v_credit   BIGINT;   -- wallet that must gain v_amount, if known
    v_type     TEXT;
    v_count    BIGINT;
    v_other    TEXT;     -- wallet_type of the other side, for deposits and withdrawals
BEGIN
    IF v_txn IS NULL THEN
        RETURN NULL;  -- not posted yet, or failed: nothing to compare
    END IF;

    CASE p_kind
        WHEN 'transfers' THEN
            v_expected := 'transfer';
            v_debit    := (p_row ->> 'source_wallet_id')::BIGINT;
            v_credit   := (p_row ->> 'destination_wallet_id')::BIGINT;
        WHEN 'deposits' THEN
            v_expected := 'deposit';
            v_credit   := (p_row ->> 'wallet_id')::BIGINT;
        WHEN 'withdrawals' THEN
            v_expected := 'withdrawal';
            v_debit    := (p_row ->> 'wallet_id')::BIGINT;
    END CASE;

    SELECT txn_type INTO v_type FROM ledger_transactions WHERE transaction_id = v_txn;
    IF v_type IS DISTINCT FROM v_expected THEN
        RETURN format('transaction %s is of type %s, expected %s', v_txn, v_type, v_expected);
    END IF;

    SELECT count(*),
           max(w.wallet_type) FILTER (WHERE e.wallet_id NOT IN (coalesce(v_debit, -1), coalesce(v_credit, -1)))
      INTO v_count, v_other
      FROM ledger_entries e
      JOIN wallets w ON w.wallet_id = e.wallet_id
     WHERE e.transaction_id = v_txn;

    IF v_count <> 2 THEN
        RETURN format('transaction %s has %s entries, expected 2', v_txn, v_count);
    END IF;
    IF v_debit IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM ledger_entries
            WHERE transaction_id = v_txn AND wallet_id = v_debit AND amount_kobo = -v_amount) THEN
        RETURN format('wallet %s is not debited %s kobo in transaction %s', v_debit, v_amount, v_txn);
    END IF;
    IF v_credit IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM ledger_entries
            WHERE transaction_id = v_txn AND wallet_id = v_credit AND amount_kobo = v_amount) THEN
        RETURN format('wallet %s is not credited %s kobo in transaction %s', v_credit, v_amount, v_txn);
    END IF;
    -- A deposit or withdrawal moves money between the customer and a system wallet.
    IF p_kind <> 'transfers' AND v_other IS DISTINCT FROM 'system' THEN
        RETURN format('the other side of transaction %s is not a system wallet', v_txn);
    END IF;
    RETURN NULL;
END $$;

CREATE FUNCTION request_check_ledger() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_problem TEXT := request_ledger_problem(TG_TABLE_NAME, to_jsonb(NEW));
BEGIN
    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION '% row does not match its ledger posting: %', TG_TABLE_NAME, v_problem
            USING ERRCODE = 'check_violation', CONSTRAINT = 'request_matches_ledger';
    END IF;
    RETURN NULL;
END $$;

-- Deferred to COMMIT, so the request row and its ledger entries can be written in either order.
CREATE CONSTRAINT TRIGGER transfers_match_ledger
    AFTER INSERT OR UPDATE ON transfers
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION request_check_ledger();

CREATE CONSTRAINT TRIGGER deposits_match_ledger
    AFTER INSERT OR UPDATE ON deposits
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION request_check_ledger();

CREATE CONSTRAINT TRIGGER withdrawals_match_ledger
    AFTER INSERT OR UPDATE ON withdrawals
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION request_check_ledger();

-- Triggers only check new rows. This view checks every existing row the same way.
CREATE VIEW v_request_ledger_mismatches AS
SELECT * FROM (
SELECT 'transfers' AS kind, transfer_id AS request_id, request_ledger_problem('transfers', to_jsonb(t)) AS problem
  FROM transfers t
UNION ALL
SELECT 'deposits', deposit_id, request_ledger_problem('deposits', to_jsonb(d))
  FROM deposits d
UNION ALL
SELECT 'withdrawals', withdrawal_id, request_ledger_problem('withdrawals', to_jsonb(w))
  FROM withdrawals w
) AS checked
 WHERE problem IS NOT NULL;
