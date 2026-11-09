-- Generates a year of synthetic Kolaro activity on top of the Portfolio 1 sample data.
-- 100,000 customers, 2,000 merchants and 2,000,000 posted transactions (about 4 million ledger entries).
-- Repeatable: setseed() fixes the random sequence.
SET search_path = wallet, public;
SET work_mem = '256MB';
SET maintenance_work_mem = '512MB';

-- Triggers (including foreign key checks and the double-entry trigger) are switched off
-- for speed. CHECK and UNIQUE constraints still apply. verify.sql proves the result is valid.
SET session_replication_role = replica;

SELECT setseed(0.42);

\echo 'Customers, merchants and wallets'
INSERT INTO customers (full_name, email, phone, date_of_birth, created_at)
SELECT 'Customer ' || g,
       'customer' || g || '@customers.example',
       '+234' || (8100000000 + g),
       DATE '1960-01-01' + (random() * 15000)::INT,
       TIMESTAMPTZ '2025-06-01' + random() * INTERVAL '150 days'
  FROM generate_series(1, 100000) AS g;

INSERT INTO merchants (business_name, rc_number, category, created_at)
SELECT 'Merchant ' || g,
       'RC' || lpad((g + 1)::TEXT, 6, '0'),
       (ARRAY['grocery', 'fuel', 'pharmacy', 'restaurant', 'electronics', 'transport'])[1 + (random() * 5)::INT],
       TIMESTAMPTZ '2025-06-01' + random() * INTERVAL '150 days'
  FROM generate_series(1, 2000) AS g;

-- Wallet numbers come from the generated customer or merchant number, not the identity
-- value, so they are the same on every run: Customer 1 owns wallet 1100000001.
INSERT INTO wallets (wallet_number, wallet_type, customer_id, opened_at)
SELECT '11' || lpad(split_part(substr(c.email, 9), '@', 1), 8, '0'), 'customer', c.customer_id, c.created_at
  FROM customers c
 WHERE c.email LIKE 'customer%@customers.example'
 ORDER BY c.customer_id;

INSERT INTO wallets (wallet_number, wallet_type, merchant_id, opened_at)
SELECT '21' || lpad(substr(m.business_name, 10), 8, '0'), 'merchant', m.merchant_id, m.created_at
  FROM merchants m
 WHERE m.business_name LIKE 'Merchant %'
 ORDER BY m.merchant_id;

\echo 'KYC documents and reviews'
INSERT INTO kyc_documents (customer_id, document_type, document_number, created_at)
SELECT c.customer_id, 'nin', 'SYNTH-NIN-' || c.customer_id, c.created_at
  FROM customers c
 WHERE NOT EXISTS (SELECT 1 FROM kyc_documents d WHERE d.customer_id = c.customer_id);

-- About 70% tier 1, 25% tier 2 and 5% tier 3.
INSERT INTO kyc_reviews (document_id, tier, status, reviewed_by, submitted_at, reviewed_at)
SELECT d.document_id,
       CASE WHEN r < 0.70 THEN 1 WHEN r < 0.95 THEN 2 ELSE 3 END,
       'approved',
       (SELECT staff_id FROM staff WHERE role = 'compliance'),
       d.created_at,
       d.created_at + INTERVAL '2 hours'
  FROM (SELECT document_id, created_at, random() AS r FROM kyc_documents) AS d
 WHERE NOT EXISTS (SELECT 1 FROM kyc_reviews v WHERE v.document_id = d.document_id);

-- Numbered lists of wallets, so a random number can pick one.
CREATE TEMP TABLE cw AS
SELECT row_number() OVER (ORDER BY wallet_number) AS n, wallet_id
  FROM wallets WHERE wallet_number LIKE '11%';
CREATE TEMP TABLE mw AS
SELECT row_number() OVER (ORDER BY wallet_number) AS n, wallet_id
  FROM wallets WHERE wallet_number LIKE '21%';
CREATE UNIQUE INDEX ON cw (n);
CREATE UNIQUE INDEX ON mw (n);
ANALYZE cw;
ANALYZE mw;

\echo 'Planning 2,000,000 transactions'
-- Activity is skewed: squaring a random number makes low-numbered customers far busier,
-- as in real systems where a few accounts are very active.
-- Kinds: 15% deposit, 10% withdrawal, 45% person-to-person transfer, 30% merchant payment.
CREATE TEMP TABLE gen AS
WITH draws AS (
    SELECT g AS n, random() AS r_kind, random() AS r_from, random() AS r_to, random() AS r_amt,
           TIMESTAMPTZ '2025-11-01' + (g::FLOAT8 / 2000000) * INTERVAL '365 days' AS ts
      FROM generate_series(1, 2000000) AS g
)
SELECT d.n,
       k.kind,
       d.ts,
       CASE k.kind WHEN 'deposit' THEN 1  -- the SETTLEMENT system wallet
                   ELSE (SELECT wallet_id FROM cw WHERE cw.n = 1 + floor(100000 * d.r_from ^ 2)::INT) END AS from_wallet,
       CASE k.kind WHEN 'withdrawal' THEN 1
                   WHEN 'merchant' THEN (SELECT wallet_id FROM mw WHERE mw.n = 1 + floor(2000 * d.r_to ^ 2)::INT)
                   WHEN 'deposit' THEN (SELECT wallet_id FROM cw WHERE cw.n = 1 + floor(100000 * d.r_from ^ 2)::INT)
                   ELSE (SELECT wallet_id FROM cw WHERE cw.n = 1 + floor(100000 * d.r_to)::INT) END AS to_wallet,
       CASE k.kind WHEN 'deposit'    THEN 500000 + floor(d.r_amt * 19500000)::BIGINT
                   WHEN 'withdrawal' THEN 100000 + floor(d.r_amt * 4900000)::BIGINT
                   WHEN 'transfer'   THEN 10000 + floor(d.r_amt * 4990000)::BIGINT
                   ELSE                   5000 + floor(d.r_amt * 1995000)::BIGINT END AS amount_kobo
  FROM draws d
 CROSS JOIN LATERAL (
    SELECT CASE WHEN d.r_kind < 0.15 THEN 'deposit'
                WHEN d.r_kind < 0.25 THEN 'withdrawal'
                WHEN d.r_kind < 0.70 THEN 'transfer'
                ELSE 'merchant' END AS kind
 ) AS k;

-- A transfer to yourself is not allowed, so redirect those to a fixed customer.
UPDATE gen SET to_wallet = (SELECT wallet_id FROM cw WHERE n = 100000)
 WHERE from_wallet = to_wallet;
UPDATE gen SET to_wallet = (SELECT wallet_id FROM cw WHERE n = 99999)
 WHERE from_wallet = to_wallet;

SELECT max(transaction_id) AS txn_base FROM ledger_transactions \gset

\echo 'Posting ledger transactions and entries'
INSERT INTO ledger_transactions (transaction_id, txn_type, narration, created_at)
OVERRIDING SYSTEM VALUE
SELECT :txn_base + n,
       CASE kind WHEN 'merchant' THEN 'transfer' ELSE kind END,
       CASE kind WHEN 'deposit' THEN 'Wallet funding'
                 WHEN 'withdrawal' THEN 'Withdrawal to bank'
                 WHEN 'merchant' THEN 'Merchant payment'
                 ELSE 'Transfer' END,
       ts
  FROM gen ORDER BY n;

INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo, created_at)
SELECT :txn_base + g.n, s.wallet_id, s.amount_kobo, g.ts
  FROM gen g
 CROSS JOIN LATERAL (VALUES (g.from_wallet, -g.amount_kobo, 1), (g.to_wallet, g.amount_kobo, 2))
       AS s (wallet_id, amount_kobo, side)
 ORDER BY g.n, s.side;

\echo 'Recording the matching requests'
INSERT INTO deposits (wallet_id, amount_kobo, channel, external_reference, status, transaction_id, created_at)
SELECT to_wallet, amount_kobo,
       (ARRAY['bank_transfer', 'card', 'ussd'])[1 + (n % 3)],
       'EXT-DEP-G' || n, 'completed', :txn_base + n, ts
  FROM gen WHERE kind = 'deposit' ORDER BY n;

INSERT INTO withdrawals (wallet_id, amount_kobo, bank_code, bank_account_number, status, transaction_id, created_at)
SELECT from_wallet, amount_kobo,
       (ARRAY['001', '002', '003'])[1 + (n % 3)],
       lpad((n % 10000000000)::TEXT, 10, '0'), 'completed', :txn_base + n, ts
  FROM gen WHERE kind = 'withdrawal' ORDER BY n;

INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, transaction_id, created_at)
SELECT from_wallet, to_wallet, amount_kobo, 'completed', :txn_base + n, ts
  FROM gen WHERE kind IN ('transfer', 'merchant') ORDER BY n;

-- About 2% of transfer attempts fail and never reach the ledger.
INSERT INTO transfers (source_wallet_id, destination_wallet_id, amount_kobo, status, failure_reason, created_at)
SELECT from_wallet, to_wallet, amount_kobo, 'failed',
       (ARRAY['insufficient funds', 'wallet frozen', 'daily limit exceeded'])[1 + (n % 3)],
       ts + INTERVAL '1 second'
  FROM gen WHERE kind = 'transfer' AND n % 23 = 0 ORDER BY n;

\echo 'Funding wallets that would otherwise have gone negative'
-- Random activity can overspend a wallet. Each such wallet gets an opening deposit,
-- dated when it opened, large enough that its running balance never drops below zero.
CREATE TEMP TABLE shortfall AS
SELECT wallet_id, -min(running) AS top_up
  FROM (SELECT e.wallet_id,
               sum(e.amount_kobo) OVER (PARTITION BY e.wallet_id ORDER BY e.created_at, e.entry_id) AS running
          FROM ledger_entries e
          JOIN wallets w ON w.wallet_id = e.wallet_id AND w.wallet_type = 'customer') AS r
 GROUP BY wallet_id
HAVING min(running) < 0;

CREATE TEMP TABLE opening AS
SELECT row_number() OVER (ORDER BY s.wallet_id) AS n, s.wallet_id, s.top_up, w.opened_at
  FROM shortfall s JOIN wallets w USING (wallet_id);

SELECT max(transaction_id) AS open_base FROM ledger_transactions \gset

INSERT INTO ledger_transactions (transaction_id, txn_type, narration, created_at)
OVERRIDING SYSTEM VALUE
SELECT :open_base + n, 'deposit', 'Opening deposit', opened_at FROM opening ORDER BY n;

INSERT INTO ledger_entries (transaction_id, wallet_id, amount_kobo, created_at)
SELECT :open_base + o.n, s.wallet_id, s.amount_kobo, o.opened_at
  FROM opening o
 CROSS JOIN LATERAL (VALUES (1::BIGINT, -o.top_up, 1), (o.wallet_id, o.top_up, 2))
       AS s (wallet_id, amount_kobo, side)
 ORDER BY o.n, s.side;

INSERT INTO deposits (wallet_id, amount_kobo, channel, external_reference, status, transaction_id, created_at)
SELECT wallet_id, top_up, 'bank_transfer', 'EXT-DEP-OPEN' || n, 'completed', :open_base + n, opened_at
  FROM opening ORDER BY n;

\echo 'Setting stored balances from the ledger'
UPDATE wallets w
   SET balance_kobo = s.total, version = s.entries
  FROM (SELECT wallet_id, sum(amount_kobo) AS total, count(*) AS entries
          FROM ledger_entries GROUP BY wallet_id) AS s
 WHERE s.wallet_id = w.wallet_id;

-- Rows inserted with OVERRIDING SYSTEM VALUE don't advance the identity sequence.
SELECT setval(pg_get_serial_sequence('wallet.ledger_transactions', 'transaction_id'),
              (SELECT max(transaction_id) FROM ledger_transactions));

SET session_replication_role = origin;

\echo 'Vacuuming and collecting statistics'
VACUUM ANALYZE;
