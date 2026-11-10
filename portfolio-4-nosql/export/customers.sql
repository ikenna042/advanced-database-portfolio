-- One document per customer: profile, wallet summary and KYC history embedded.
-- Five tables in PostgreSQL (customers, wallets, kyc_documents, kyc_reviews, kyc_tiers)
-- become one document, because the app always reads them together.
WITH reviews_by_document AS (
    SELECT document_id,
           max(tier) FILTER (WHERE status = 'approved') AS approved_tier,
           json_agg(json_build_object(
               'tier', tier, 'status', status, 'reviewed_by_staff_id', reviewed_by,
               'submitted_at', pg_temp.d(submitted_at), 'reviewed_at', pg_temp.d(reviewed_at))
               ORDER BY review_id) AS reviews
      FROM kyc_reviews GROUP BY document_id
), documents_by_customer AS (
    SELECT d.customer_id,
           coalesce(max(r.approved_tier), 0) AS current_tier,
           json_agg(json_build_object(
               'type', d.document_type, 'number', d.document_number,
               'submitted_at', pg_temp.d(d.created_at),
               'reviews', coalesce(r.reviews, '[]'::JSON))
               ORDER BY d.document_id) AS documents
      FROM kyc_documents d
      LEFT JOIN reviews_by_document r USING (document_id)
     GROUP BY d.customer_id
)
SELECT json_build_object(
           '_id', c.customer_id,
           'full_name', c.full_name,
           'email', lower(c.email),
           'phone', c.phone,
           'date_of_birth', pg_temp.d(c.date_of_birth::TIMESTAMPTZ),
           'status', c.status,
           'created_at', pg_temp.d(c.created_at),
           'wallet', json_build_object(
               'wallet_number', w.wallet_number, 'status', w.status,
               'balance_kobo', w.balance_kobo, 'opened_at', pg_temp.d(w.opened_at)),
           'kyc', json_build_object(
               'current_tier', coalesce(k.current_tier, 0),
               'documents', coalesce(k.documents, '[]'::JSON)))
  FROM customers c
  JOIN wallets w ON w.customer_id = c.customer_id
  LEFT JOIN documents_by_customer k ON k.customer_id = c.customer_id
 ORDER BY c.customer_id;
