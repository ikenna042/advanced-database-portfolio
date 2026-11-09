-- Q8. Customer engagement: active customer wallets with no movement since 1 August 2026.
SELECT count(*) AS dormant_wallets
  FROM wallet.wallets w
 WHERE w.wallet_type = 'customer'
   AND w.status = 'active'
   AND NOT EXISTS (SELECT 1 FROM wallet.ledger_entries e
                    WHERE e.wallet_id = w.wallet_id
                      AND e.created_at >= TIMESTAMPTZ '2026-08-01');
