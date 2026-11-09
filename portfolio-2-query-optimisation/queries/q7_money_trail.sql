-- Q7. Fraud investigation: follow money out of a wallet for up to three hops.
-- Each hop must happen within 48 hours of the previous one, and a wallet is not revisited.
WITH RECURSIVE trail AS (
    SELECT t.transfer_id, t.source_wallet_id, t.destination_wallet_id, t.amount_kobo, t.created_at,
           1 AS hop, ARRAY[t.source_wallet_id, t.destination_wallet_id] AS path
      FROM wallet.transfers t
     WHERE t.source_wallet_id = (SELECT wallet_id FROM wallet.wallets WHERE wallet_number = '1100000001')
       AND t.status = 'completed'
       AND t.created_at >= TIMESTAMPTZ '2026-10-01'
       AND t.created_at <  TIMESTAMPTZ '2026-10-02'
    UNION ALL
    SELECT n.transfer_id, n.source_wallet_id, n.destination_wallet_id, n.amount_kobo, n.created_at,
           tr.hop + 1, tr.path || n.destination_wallet_id
      FROM trail tr
      JOIN wallet.transfers n
        ON n.source_wallet_id = tr.destination_wallet_id
       AND n.status = 'completed'
       AND n.created_at >  tr.created_at
       AND n.created_at <  tr.created_at + INTERVAL '48 hours'
     WHERE tr.hop < 3
       AND n.destination_wallet_id <> ALL (tr.path)
)
SELECT hop, count(*) AS transfers, count(DISTINCT destination_wallet_id) AS wallets_reached,
       sum(amount_kobo) AS value_kobo
  FROM trail
 GROUP BY hop
 ORDER BY hop;
