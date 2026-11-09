| Query | Baseline median (ms) | Indexed median (ms) | Speed-up | Same result? |
|---|---:|---:|---:|---|
| q1_customer_statement | 111.496 | 13.421 | 8.3x | Yes |
| q1b_customer_statement_rewritten | 208.020 | 0.417 | 498.8x | Yes |
| q2a_customer_lookup_naive | 7.509 | 8.239 | 0.9x | Yes |
| q2b_customer_lookup_rewritten | 0.094 | 0.085 | 1.1x | Yes |
| q3_daily_volume | 323.640 | 254.164 | 1.3x | Yes |
| q3b_daily_volume_rewritten | 296.493 | 43.031 | 6.9x | Yes |
| q4_top_merchants | 84.776 | 17.606 | 4.8x | Yes |
| q5_balance_reconciliation | 1376.706 | 669.756 | 2.1x | Yes |
| q6_failed_transfers_queue | 35.558 | 0.725 | 49.0x | Yes |
| q7_money_trail | 437.413 | 0.306 | 1429.5x | Yes |
| q8_dormant_wallets | 111.260 | 157.597 | 0.7x | Yes |
