-- The concurrency-safe transfer procedure. The caller decides where the transaction
-- begins and ends, so this is a function rather than a procedure with COMMIT.
-- Designed for READ COMMITTED, PostgreSQL's default. Under REPEATABLE READ or
-- SERIALIZABLE it is still correct, but the caller must retry on SQLSTATE 40001.
SET search_path = wallet, public;

CREATE FUNCTION transfer(
    p_source          CHAR(10),
    p_destination     CHAR(10),
    p_amount_kobo     BIGINT,
    p_idempotency_key TEXT,
    p_narration       TEXT DEFAULT 'Transfer'
)
RETURNS TABLE (transfer_id BIGINT, status TEXT, failure_reason TEXT, transaction_id BIGINT, replayed BOOLEAN)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_source   wallets%ROWTYPE;
    v_dest     wallets%ROWTYPE;
    v_hash     TEXT := md5(concat_ws('|', p_source, p_destination, p_amount_kobo));
    v_key      idempotency_keys%ROWTYPE;
    v_transfer BIGINT;
    v_txn      BIGINT;
    v_reason   TEXT;
BEGIN
    -- 0. Reject malformed requests outright. These raise errors, so nothing is recorded.
    IF p_amount_kobo IS NULL OR p_amount_kobo <= 0 THEN
        RAISE EXCEPTION 'amount must be a positive number of kobo' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT * INTO v_source FROM wallets WHERE wallet_number = p_source;
    SELECT * INTO v_dest   FROM wallets WHERE wallet_number = p_destination;
    IF v_source.wallet_id IS NULL OR v_dest.wallet_id IS NULL THEN
        RAISE EXCEPTION 'unknown wallet number' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_source.wallet_type <> 'customer' THEN
        RAISE EXCEPTION 'transfers must come from a customer wallet' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_source.wallet_id = v_dest.wallet_id THEN
        RAISE EXCEPTION 'a wallet cannot send money to itself' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- 1. Claim the idempotency key. If another session is processing the same key,
    --    this INSERT waits for it to finish, then does nothing.
    INSERT INTO idempotency_keys (customer_id, idempotency_key, request_hash)
    VALUES (v_source.customer_id, p_idempotency_key, v_hash)
    ON CONFLICT DO NOTHING;

    IF NOT FOUND THEN
        -- The key was used before: return the stored outcome instead of posting again.
        SELECT * INTO v_key FROM idempotency_keys k
         WHERE k.customer_id = v_source.customer_id AND k.idempotency_key = p_idempotency_key;
        IF v_key.request_hash <> v_hash THEN
            RAISE EXCEPTION 'idempotency key % was already used for a different request', p_idempotency_key
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
        RETURN QUERY
            SELECT t.transfer_id, t.status, t.failure_reason, t.transaction_id, TRUE
              FROM transfers t WHERE t.transfer_id = v_key.transfer_id;
        RETURN;
    END IF;

    -- 2. Lock both wallets, always lowest wallet_id first. Two transfers in opposite
    --    directions then queue for the same first lock instead of deadlocking.
    PERFORM 1 FROM wallets w
      WHERE w.wallet_id IN (v_source.wallet_id, v_dest.wallet_id)
      ORDER BY w.wallet_id
      FOR UPDATE;

    -- 3. Re-read both wallets. Under READ COMMITTED each statement sees the latest
    --    committed data, so these values can't change until this transaction ends.
    SELECT * INTO v_source FROM wallets WHERE wallet_id = v_source.wallet_id;
    SELECT * INTO v_dest   FROM wallets WHERE wallet_id = v_dest.wallet_id;

    v_reason := CASE
        WHEN v_source.status <> 'active'          THEN 'source wallet is ' || v_source.status
        WHEN v_dest.status = 'closed'             THEN 'destination wallet is closed'
        WHEN v_source.balance_kobo < p_amount_kobo THEN 'insufficient funds'
    END;

    -- 4. Record the outcome. A business failure is stored, not raised, so the
    --    customer and support staff can see it, and a retry returns it.
    IF v_reason IS NOT NULL THEN
        INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, failure_reason)
        VALUES (v_source.wallet_id, v_dest.wallet_id, p_amount_kobo, 'failed', v_reason)
        RETURNING transfer_id INTO v_transfer;
    ELSE
        INSERT INTO ledger_transactions (txn_type, narration)
        VALUES ('transfer', p_narration)
        RETURNING transaction_id INTO v_txn;

        -- The ledger_entries_apply trigger updates both balances.
        INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
        VALUES (v_txn, v_source.wallet_id, -p_amount_kobo),
               (v_txn, v_dest.wallet_id,    p_amount_kobo);

        INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, transaction_id)
        VALUES (v_source.wallet_id, v_dest.wallet_id, p_amount_kobo, 'completed', v_txn)
        RETURNING transfer_id INTO v_transfer;
    END IF;

    UPDATE idempotency_keys k
       SET transfer_id = v_transfer, transaction_id = v_txn
     WHERE k.customer_id = v_source.customer_id AND k.idempotency_key = p_idempotency_key;

    RETURN QUERY SELECT v_transfer,
                        CASE WHEN v_reason IS NULL THEN 'completed' ELSE 'failed' END,
                        v_reason, v_txn, FALSE;
END $$;
