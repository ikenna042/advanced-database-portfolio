-- Statement buckets for August to October 2026: one document per wallet, month and
-- block of up to 500 entries (the "bucket pattern"). Each entry carries the balance
-- after it and the counterparty's details, copied in so the statement screen needs
-- no joins. System wallets are left out: they are internal, not shown to anyone.
WITH running AS (
    SELECT e.entry_id, e.wallet_id, e.transaction_id, e.amount_kobo, e.created_at,
           sum(e.amount_kobo) OVER (PARTITION BY e.wallet_id ORDER BY e.created_at, e.entry_id) AS balance_after
      FROM ledger_entries e
), recent AS (
    SELECT r.*,
           to_char(r.created_at AT TIME ZONE 'UTC', 'YYYY-MM') AS month,
           (row_number() OVER (PARTITION BY r.wallet_id, date_trunc('month', r.created_at AT TIME ZONE 'UTC')
                               ORDER BY r.created_at, r.entry_id) - 1) / 500 AS block
      FROM running r
     WHERE r.created_at >= TIMESTAMPTZ '2026-08-01 00:00+00'
       AND r.created_at <  TIMESTAMPTZ '2026-11-01 00:00+00'
), detailed AS (
    SELECT r.*, t.txn_type, t.narration,
           cw.wallet_number AS cp_number, cw.wallet_type AS cp_type,
           m.business_name AS cp_merchant, m.category AS cp_category
      FROM recent r
      JOIN ledger_transactions t ON t.transaction_id = r.transaction_id
      JOIN ledger_entries o      ON o.transaction_id = r.transaction_id AND o.wallet_id <> r.wallet_id
      JOIN wallets cw            ON cw.wallet_id = o.wallet_id
      LEFT JOIN merchants m      ON m.merchant_id = cw.merchant_id
)
SELECT json_build_object(
           '_id', w.wallet_number || ':' || d.month || ':' || d.block,
           'wallet_number', w.wallet_number,
           'wallet_type', w.wallet_type,
           'month', d.month,
           'block', d.block,
           'entry_count', count(*),
           'opening_balance_kobo', (array_agg(d.balance_after - d.amount_kobo ORDER BY d.created_at, d.entry_id))[1],
           'closing_balance_kobo', (array_agg(d.balance_after ORDER BY d.created_at DESC, d.entry_id DESC))[1],
           'money_in_kobo',  coalesce(sum(d.amount_kobo) FILTER (WHERE d.amount_kobo > 0), 0),
           'money_out_kobo', coalesce(-sum(d.amount_kobo) FILTER (WHERE d.amount_kobo < 0), 0),
           'entries', json_agg(json_strip_nulls(json_build_object(
               'entry_id', d.entry_id,
               'at', pg_temp.d(d.created_at),
               'amount_kobo', d.amount_kobo,
               'balance_after_kobo', d.balance_after,
               'type', d.txn_type,
               'narration', d.narration,
               'counterparty', json_strip_nulls(json_build_object(
                   'wallet_number', d.cp_number, 'kind', d.cp_type,
                   'merchant', d.cp_merchant, 'category', d.cp_category))))
               ORDER BY d.created_at, d.entry_id))
  FROM detailed d
  JOIN wallets w ON w.wallet_id = d.wallet_id
 WHERE w.wallet_type <> 'system'
 GROUP BY w.wallet_number, w.wallet_type, d.month, d.block;
