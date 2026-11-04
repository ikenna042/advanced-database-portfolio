-- Rules a single-row CHECK cannot express, enforced with triggers.
SET search_path = wallet, public;

-- 1. Every ledger transaction must have at least two entries that sum to zero.
--    Deferred to COMMIT, because the entries are inserted one at a time.
CREATE FUNCTION ledger_check_balanced() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    entry_count BIGINT;
    net_kobo    BIGINT;
BEGIN
    SELECT count(*), coalesce(sum(amount_kobo), 0)
      INTO entry_count, net_kobo
      FROM ledger_entries
     WHERE transaction_id = NEW.transaction_id;

    IF entry_count < 2 OR net_kobo <> 0 THEN
        RAISE EXCEPTION 'ledger transaction % is unbalanced: % entries, net % kobo',
            NEW.transaction_id, entry_count, net_kobo
            USING ERRCODE = 'check_violation', CONSTRAINT = 'ledger_transaction_balanced';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ledger_entries_balanced
    AFTER INSERT ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ledger_check_balanced();

CREATE CONSTRAINT TRIGGER ledger_transactions_balanced
    AFTER INSERT ON ledger_transactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ledger_check_balanced();

-- 2. The ledger and audit log are append-only. Mistakes are corrected with a reversal.
CREATE FUNCTION reject_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: % is not allowed', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
END $$;

CREATE TRIGGER ledger_transactions_append_only BEFORE UPDATE OR DELETE ON ledger_transactions
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER ledger_transactions_no_truncate BEFORE TRUNCATE ON ledger_transactions
    FOR EACH STATEMENT EXECUTE FUNCTION reject_change();

CREATE TRIGGER ledger_entries_append_only BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER ledger_entries_no_truncate BEFORE TRUNCATE ON ledger_entries
    FOR EACH STATEMENT EXECUTE FUNCTION reject_change();

CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION reject_change();

-- 3. A reversal must be a 'reversal' transaction that exactly mirrors the original.
CREATE FUNCTION reversal_check_mirror() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ledger_transactions
                    WHERE transaction_id = NEW.reversal_transaction_id AND txn_type = 'reversal') THEN
        RAISE EXCEPTION 'transaction % is not of type reversal', NEW.reversal_transaction_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'reversal_type_is_reversal';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM (SELECT wallet_id, amount_kobo FROM ledger_entries
                 WHERE transaction_id = NEW.original_transaction_id) AS o
          FULL JOIN (SELECT wallet_id, amount_kobo FROM ledger_entries
                      WHERE transaction_id = NEW.reversal_transaction_id) AS r
            ON o.wallet_id = r.wallet_id
         WHERE o.amount_kobo IS NULL OR r.amount_kobo IS NULL OR o.amount_kobo <> -r.amount_kobo
    ) THEN
        RAISE EXCEPTION 'transaction % does not mirror transaction %',
            NEW.reversal_transaction_id, NEW.original_transaction_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'reversal_mirrors_original';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER reversals_mirror_original
    AFTER INSERT ON reversals
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION reversal_check_mirror();

-- 4. Every change of wallet status is written to the audit log.
--    The acting staff member comes from the kolaro.staff_id session setting, if set.
CREATE FUNCTION wallet_audit_status() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (actor_staff_id, action, entity_type, entity_id, details)
    VALUES (NULLIF(current_setting('kolaro.staff_id', TRUE), '')::BIGINT,
            'wallet_status_changed', 'wallet', NEW.wallet_id,
            jsonb_build_object('from', OLD.status, 'to', NEW.status));
    RETURN NULL;
END $$;

CREATE TRIGGER wallets_audit_status
    AFTER UPDATE OF status ON wallets
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION wallet_audit_status();
