# Normalisation

This worked example starts from the flat report a finance team might keep in a spreadsheet, and normalises it to Boyce-Codd Normal Form (BCNF). The result is the Kolaro schema.

## Starting point: unnormalised form (UNF)

One row per transaction, with a repeating group of wallet movements:

`TRANSACTION_REPORT(txn_id, txn_type, narration, txn_date, { wallet_number, currency, balance, customer_id, customer_name, customer_email, amount }, bank_code, bank_name, bank_account_number)`

| Problem | Example |
|---|---|
| Update anomaly | Changing a customer's email means editing every row they appear in. |
| Insert anomaly | A new customer can't be recorded until they make a transaction. |
| Delete anomaly | Deleting a customer's only transaction also loses the customer. |

## First Normal Form (1NF)

**Rule:** every value is atomic, with no repeating groups.

The wallet movements become one row each, and the key becomes `(txn_id, wallet_number)`:

`R1(txn_id, wallet_number, txn_type, narration, txn_date, currency, balance, customer_id, customer_name, customer_email, amount, bank_code, bank_name, bank_account_number)`

The key relies on a business rule: a wallet appears at most once per transaction. The schema enforces this with `UNIQUE (transaction_id, wallet_id)`.

## Second Normal Form (2NF)

**Rule:** in 1NF, and no non-key attribute depends on only part of the key.

Functional dependencies in R1:

| Dependency | Type |
|---|---|
| `txn_id, wallet_number → amount` | Full, so it stays |
| `txn_id → txn_type, narration, txn_date, bank_code, bank_account_number` | Partial |
| `wallet_number → currency, balance, customer_id, customer_name, customer_email` | Partial |
| `bank_code → bank_name` | Non-key determinant, handled in 3NF |

Removing the partial dependencies gives:

- `ENTRY(txn_id, wallet_number, amount)`
- `TXN(txn_id, txn_type, narration, txn_date, bank_code, bank_name, bank_account_number)`
- `WALLET(wallet_number, currency, balance, customer_id, customer_name, customer_email)`

## Third Normal Form (3NF)

**Rule:** in 2NF, and no non-key attribute depends on another non-key attribute.

| Transitive dependency | Resolution |
|---|---|
| `wallet_number → customer_id → customer_name, customer_email` | Move the customer attributes to `customers`. |
| `txn_id → bank_code → bank_name` | Move the bank name to `banks`. |

A further change comes from the business process. Bank details only apply to withdrawals, and a withdrawal request exists before it is posted and may fail. Those attributes therefore move to `withdrawals`, rather than sitting as NULLs on every ledger transaction. `deposits` and `transfers` follow the same pattern.

## Boyce-Codd Normal Form (BCNF)

**Rule:** the determinant of every non-trivial functional dependency is a candidate key.

### A violation found during design

The first design had one KYC table:

`kyc_records(kyc_id, customer_id, document_type, document_number, tier, status, reviewed_by, reviewed_at)`

A document belongs to one person, so `document_type, document_number → customer_id`. But the same document can be reviewed many times, for example after a rejection, so those two columns are not a candidate key. That breaks BCNF: a document's owner would be repeated on every review, and could end up contradicting itself.

The fix was to split it into `kyc_documents`, where `(document_type, document_number)` is a true candidate key, and `kyc_reviews`.

### Check of the main tables

| Table | Candidate keys | Other determinants? | BCNF |
|---|---|---|---|
| `customers` | `customer_id`, `email`, `phone` | None | Yes |
| `merchants` | `merchant_id`, `rc_number` | None | Yes |
| `staff` | `staff_id`, `email` | None | Yes |
| `banks` | `bank_code`, `bank_name` | None | Yes |
| `kyc_tiers` | `tier` | None | Yes |
| `kyc_documents` | `document_id`, `(document_type, document_number)` | None | Yes |
| `kyc_reviews` | `review_id` | None | Yes |
| `wallets` | `wallet_id`, `wallet_number` | None within the table (see below) | Yes |
| `ledger_transactions` | `transaction_id` | None | Yes |
| `ledger_entries` | `entry_id`, `(transaction_id, wallet_id)` | None | Yes |
| `reversals` | `reversal_id`, `original_transaction_id`, `reversal_transaction_id` | None | Yes |
| `idempotency_keys` | `(customer_id, idempotency_key)` | None | Yes |

Two wallets columns need a note. The `UNIQUE` constraints with `customer_id` and `merchant_id` include `currency`, because a customer could hold one wallet per currency if more are added later. Only NGN is allowed for now. `wallet_type` could be inferred from which owner column is filled, but it is kept so that the CHECK constraint states the intended owner explicitly.

## Deliberate denormalisation

Normalising further would remove these. They stay because each has a practical reason and a control against drifting out of step.

| Redundancy | Why it stays | Control |
|---|---|---|
| `wallets.balance_kobo` could be derived with `SUM(ledger_entries.amount_kobo)` | Checking funds on every transfer shouldn't need to sum a wallet's entire history. It also gives transactions one row to lock, which Portfolio 3 relies on. | `v_wallet_balance_audit` compares the two values for every wallet. |
| `amount_kobo` on `deposits`, `withdrawals` and `transfers` repeats the ledger amount once posted | These records exist before posting, and failed ones are never posted, so they need their own amount. | Completed requests must link to a ledger transaction. Matching the amounts is not enforced by the schema (see the README). |

The opposite choice was made for a customer's KYC tier. It isn't needed on every transaction path yet, so it is derived through `v_customer_kyc_tier` instead of being stored.
