-- A transfer on the sharded ledger, following Portfolio 3's transfer(): lock both wallets
-- in wallet_id order, re-check, then post. It takes wallet ids rather than wallet numbers,
-- because wallet_number is not the shard key: finding a wallet by number would mean asking
-- every shard. (A real system would keep a small lookup from number to id.)
-- Every statement below goes to exactly one shard. When the shards it wrote to are on more
-- than one worker, Citus commits them all with two-phase commit.
CREATE FUNCTION wallet.transfer_by_id(p_source BIGINT, p_destination BIGINT, p_amount_kobo BIGINT)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_first   BIGINT := least(p_source, p_destination);
    v_second  BIGINT := greatest(p_source, p_destination);
    v_balance BIGINT;
    v_status  TEXT;
    v_txn     BIGINT;
BEGIN
    IF p_source = p_destination OR p_amount_kobo <= 0 THEN
        RAISE EXCEPTION 'invalid transfer request';
    END IF;

    -- Lock in a fixed order, as in Portfolio 3, so two opposite transfers cannot deadlock.
    PERFORM 1 FROM wallet.wallets WHERE wallet_id = v_first FOR UPDATE;
    PERFORM 1 FROM wallet.wallets WHERE wallet_id = v_second FOR UPDATE;

    SELECT balance_kobo, status INTO v_balance, v_status FROM wallet.wallets WHERE wallet_id = p_source;
    IF v_status <> 'active' OR v_balance < p_amount_kobo THEN
        INSERT INTO wallet.transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, failure_reason)
        VALUES (p_source, p_destination, p_amount_kobo, 'failed',
                CASE WHEN v_status <> 'active' THEN 'source wallet is not active' ELSE 'insufficient funds' END);
        RETURN 'failed';
    END IF;

    INSERT INTO wallet.ledger_transactions (txn_type, narration)
    VALUES ('transfer', 'Transfer') RETURNING transaction_id INTO v_txn;
    INSERT INTO wallet.ledger_entries (transaction_id, wallet_id, amount_kobo)
    VALUES (v_txn, p_source, -p_amount_kobo);
    INSERT INTO wallet.ledger_entries (transaction_id, wallet_id, amount_kobo)
    VALUES (v_txn, p_destination, p_amount_kobo);
    UPDATE wallet.wallets SET balance_kobo = balance_kobo - p_amount_kobo, version = version + 1 WHERE wallet_id = p_source;
    UPDATE wallet.wallets SET balance_kobo = balance_kobo + p_amount_kobo, version = version + 1 WHERE wallet_id = p_destination;
    INSERT INTO wallet.transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, transaction_id)
    VALUES (p_source, p_destination, p_amount_kobo, 'completed', v_txn);
    RETURN 'completed';
END;
$$;

-- Which shard and which worker hold each wallet. Used to choose wallets for the demos.
-- The wallets are first fetched to the coordinator (MATERIALIZED), and only then matched with
-- Citus's metadata tables there. Without that, Citus pushes the whole query to the workers,
-- where 'wallet.wallets'::regclass has a different OID and nothing matches.
CREATE VIEW wallet.wallet_placement AS
WITH w AS MATERIALIZED (SELECT wallet_id, balance_kobo FROM wallet.wallets)
SELECT w.wallet_id, w.balance_kobo, s.shardid, n.nodename
  FROM w
  JOIN pg_dist_shard s
    ON s.logicalrelid = 'wallet.wallets'::regclass
   AND worker_hash(w.wallet_id) BETWEEN s.shardminvalue::int AND s.shardmaxvalue::int
  JOIN pg_dist_placement pl ON pl.shardid = s.shardid
  JOIN pg_dist_node n ON n.groupid = pl.groupid;
