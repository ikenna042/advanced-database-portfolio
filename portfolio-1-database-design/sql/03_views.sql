-- Audit views over the schema.
SET search_path = wallet, public;

-- Compares each wallet's stored balance with the sum of its ledger entries.
CREATE VIEW v_wallet_balance_audit AS
SELECT w.wallet_id,
       w.wallet_number,
       w.wallet_type,
       w.balance_kobo                            AS stored_kobo,
       coalesce(sum(e.amount_kobo), 0)           AS ledger_kobo,
       w.balance_kobo - coalesce(sum(e.amount_kobo), 0) AS difference_kobo
  FROM wallets w
  LEFT JOIN ledger_entries e ON e.wallet_id = w.wallet_id
 GROUP BY w.wallet_id;

-- Double-entry check: all entries across the whole ledger must net to zero.
CREATE VIEW v_ledger_trial_balance AS
SELECT count(*)                      AS entry_count,
       coalesce(sum(amount_kobo), 0) AS net_kobo
  FROM ledger_entries;

-- A customer's current KYC tier is derived from approved reviews, not stored twice.
CREATE VIEW v_customer_kyc_tier AS
SELECT c.customer_id,
       c.full_name,
       coalesce(max(r.tier) FILTER (WHERE r.status = 'approved'), 0) AS current_tier
  FROM customers c
  LEFT JOIN kyc_documents d ON d.customer_id = c.customer_id
  LEFT JOIN kyc_reviews r   ON r.document_id = d.document_id
 GROUP BY c.customer_id;
