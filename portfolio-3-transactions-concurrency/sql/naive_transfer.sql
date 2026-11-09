-- DELIBERATELY UNSAFE. Used only in Part A, on the plain Portfolio 1 schema, to show
-- what goes wrong without concurrency control. It does what a simple application
-- might do: read the balances, check funds, then write back the new balances as
-- absolute values. It takes no locks before reading and locks wallets in request order.
SET search_path = wallet, public;

CREATE FUNCTION naive_transfer(p_source CHAR(10), p_destination CHAR(10), p_amount_kobo BIGINT)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_source_id  BIGINT;
    v_source_bal BIGINT;
    v_dest_id    BIGINT;
    v_dest_bal   BIGINT;
    v_txn        BIGINT;
BEGIN
    -- Read without locking.
    SELECT wallet_id, balance_kobo INTO v_source_id, v_source_bal FROM wallets WHERE wallet_number = p_source;
    SELECT wallet_id, balance_kobo INTO v_dest_id,   v_dest_bal   FROM wallets WHERE wallet_number = p_destination;

    IF v_source_bal < p_amount_kobo THEN
        RETURN 'insufficient funds';
    END IF;

    INSERT INTO ledger_transactions (txn_type, narration)
    VALUES ('transfer', 'Naive transfer')
    RETURNING transaction_id INTO v_txn;

    INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
    VALUES (v_txn, v_source_id, -p_amount_kobo), (v_txn, v_dest_id, p_amount_kobo);

    -- Write back values computed from the earlier reads. If another transaction
    -- changed these wallets in between, its change is overwritten: a lost update.
    UPDATE wallets SET balance_kobo = v_source_bal - p_amount_kobo WHERE wallet_id = v_source_id;
    UPDATE wallets SET balance_kobo = v_dest_bal   + p_amount_kobo WHERE wallet_id = v_dest_id;
    RETURN 'completed';
END $$;

-- Posts a balanced two-entry ledger transaction without touching any balance.
-- Used by the lost-update demo, which then updates balances in different ways.
CREATE FUNCTION post_entries(p_source CHAR(10), p_destination CHAR(10), p_amount_kobo BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_txn BIGINT;
BEGIN
    INSERT INTO ledger_transactions (txn_type, narration)
    VALUES ('transfer', 'Lost update demo')
    RETURNING transaction_id INTO v_txn;

    INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo)
    SELECT v_txn, wallet_id, CASE WHEN wallet_number = p_source THEN -p_amount_kobo ELSE p_amount_kobo END
      FROM wallets WHERE wallet_number IN (p_source, p_destination);
    RETURN v_txn;
END $$;
