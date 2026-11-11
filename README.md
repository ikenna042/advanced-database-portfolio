# Advanced Database Systems Portfolio

MIT 8103 Advanced Database Systems, First Semester Continuous Assessment, 2026/2027.

**Student:** Ikenna Odoh, 2026/A/MIT/0310

## Selected case study: Kolaro Wallet

Kolaro Wallet is a **simulated organisation**, invented for this portfolio. It is not a real company, and all data in this repository is synthetic.

| Item | Description |
|---|---|
| **Nature of the business** | A Nigerian digital wallet that lets customers hold naira, fund their wallets, send money to each other and pay merchants. |
| **Users of the database** | Customers (through the app), merchants, customer support staff, compliance officers, finance and reconciliation staff, and auditors. |
| **Major data** | Customers, KYC records, wallets, merchants, ledger transactions, ledger entries, transfers, deposits, withdrawals, reversals, idempotency keys and audit logs. |
| **Key operations** | Open a wallet, deposit, withdraw, transfer funds, reverse a failed transaction, freeze a wallet, produce a customer statement, audit balances against the ledger and report on transaction volumes. |

The same case study is used across all five portfolio activities.

## Repository structure

| Folder | Activity | Marks |
|---|---|---|
| [portfolio-1-database-design](portfolio-1-database-design/) | Database Design and Modelling | 7 |
| [portfolio-2-query-optimisation](portfolio-2-query-optimisation/) | Query Processing and Optimisation | 7 |
| [portfolio-3-transactions-concurrency](portfolio-3-transactions-concurrency/) | Transactions and Concurrency | 7 |
| [portfolio-4-nosql](portfolio-4-nosql/) | NoSQL and Advanced Data Models | 7 |
| [portfolio-5-distributed-cloud](portfolio-5-distributed-cloud/) | Distributed and Cloud Database Exercise | 6 |
| [final-documentation](final-documentation/) | Final Documentation: the 3-page summary submitted through the LMS ([PDF](final-documentation/Odoh_Ikenna_FinalDocumentation.pdf)) | 6 |
| [AI_USE_DECLARATION.md](AI_USE_DECLARATION.md) | AI Use Declaration | |

## Running the lab

You need Docker with Compose. Start the databases and check that they respond:

```bash
docker compose up -d --wait
./scripts/check-stack.sh
```

| Database | Version | Local address |
|---|---|---|
| PostgreSQL | 16 | `localhost:5440`, database and user `kolaro` |
| MongoDB | 7.0 | `localhost:27018`, user `kolaro` |
| Redis | 7 | `localhost:6380` |

The default passwords are set in [docker-compose.yml](docker-compose.yml) and are only for this local lab. To stop the lab, run `docker compose down`. To also delete its data, run `docker compose down -v`.

Each portfolio folder has its own README with the commands to reproduce its work.
