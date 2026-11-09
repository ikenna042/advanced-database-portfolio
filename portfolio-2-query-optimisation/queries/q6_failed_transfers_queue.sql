-- Q6. Support queue: the 50 most recent failed transfers.
SELECT t.transfer_id, t.created_at, s.wallet_number AS from_wallet, t.amount_kobo, t.failure_reason
  FROM wallet.transfers t
  JOIN wallet.wallets s ON s.wallet_id = t.source_wallet_id
 WHERE t.status = 'failed'
 ORDER BY t.created_at DESC
 LIMIT 50;
