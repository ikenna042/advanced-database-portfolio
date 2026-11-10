-- One document per completed transfer in October 2026: an edge in the money graph.
SELECT json_build_object(
           '_id', t.transfer_id,
           'from', s.wallet_number,
           'to', d.wallet_number,
           'amount_kobo', t.amount_kobo,
           'at', pg_temp.d(t.created_at))
  FROM transfers t
  JOIN wallets s ON s.wallet_id = t.source_wallet_id
  JOIN wallets d ON d.wallet_id = t.destination_wallet_id
 WHERE t.status = 'completed'
   AND t.created_at >= TIMESTAMPTZ '2026-10-01 00:00+00'
   AND t.created_at <  TIMESTAMPTZ '2026-11-01 00:00+00';
