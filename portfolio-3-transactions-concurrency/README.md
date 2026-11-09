# Portfolio 3: Transactions and Concurrency

How Kolaro Wallet keeps money correct when many requests run at once. Part A shows what goes wrong with naive code on the Portfolio 1 schema. Part B adds database rules and a concurrency-safe transfer procedure, then demonstrates commit, rollback, isolation levels, locking, deadlocks, crash recovery and a concurrent stress test.

## Headline result

Five 15-second stress runs, each with 16 clients sending random transfers among 20 wallets funded with N10,000 each. Transfers only move money between those wallets, so their total must stay at exactly 20,000,000 kobo.

| Run | Code | Isolation | Transfers committed | Per second | Money created from nothing | Wallets where balance ≠ ledger |
|---|---|---|---:|---:|---:|---:|
| A | `naive_transfer` | Read committed | 578 | 36 | **2,184,302 kobo** | **20 of 20** |
| A | `naive_transfer`, 100 ms deadlock timeout | Read committed | 2,356 | 155 | **6,218,761 kobo** | **20 of 20** |
| A | `naive_transfer` | Serializable | 390 | 26 | 0 | 0 |
| **B** | **`transfer()`** | **Read committed** | **25,317** | **1,686** | **0** | **0** |
| B | `transfer()` | Serializable | 4,567 | 304 | 0 | 0 |

- **The naive code created money.** Lost updates overwrote other transactions' changes to balances. The ledger stayed balanced, because each ledger transaction is checked separately, but every stored balance drifted away from it.
- **The safe procedure was correct and 47 times faster.** It uses row locks in a fixed order, so it never deadlocked and never needed a retry.
- **SERIALIZABLE alone also prevented the errors**, even for the naive code. But with this much contention, about half the transfers still failed after 10 attempts. It suits rules that span many rows (B3), not hot rows that a lock handles better.

Full output is in [evidence/](evidence/), one file per run, named `stress-*.txt`.

## How to run it

From the repository root, with the lab running:

```bash
./portfolio-3-transactions-concurrency/run.sh
```

It takes about 2 minutes. It rebuilds the schema several times and **kills the PostgreSQL container once** to test crash recovery, then restarts it.

## How the demonstrations work

The brief asks for concurrency evidence, which needs two sessions acting at the same time. Each demo is a SQL script run by `psql`, which is **session A**. Session A opens a second connection, **session B**, through the `dblink` extension ([demos/_sessions.sql](demos/_sessions.sql)). Because one script drives both sessions, their statements interleave in the same order every run.

- `pg_temp.b('...')` runs a statement in session B and returns its result, or its error message.
- `pg_temp.b_start('...')` starts a statement in B without waiting. That's how B blocks on a lock while A carries on.
- `pg_temp.session_b` shows what B is doing according to the server. `Lock / transactionid` means B is waiting for another transaction's row lock.

Each evidence file shows every statement, then its result, labelled `[A]` or `[B]`.

## Part A: the problem

[sql/naive_transfer.sql](sql/naive_transfer.sql) is deliberately unsafe. It reads both balances without locking, checks funds, and writes back new balances as absolute values. Like a simple application, it locks wallets in the order the request names them.

**A1. Lost update** ([evidence](evidence/a1_lost_update.txt)):

| Scenario | What happened |
|---|---|
| A1.1 Read committed, absolute writes | Both sessions read 6,650,000. A wrote 6,550,000, then B wrote 6,450,000. A's N1,000 debit was lost: the stored balance is 100,000 kobo higher than the ledger. |
| A1.2 Repeatable read, same code | B's update failed with `could not serialize access due to concurrent update` (SQLSTATE 40001). B retried with a fresh snapshot and succeeded. Nothing new was lost. |
| A1.3 Read committed, relative writes | `balance = balance - amount`. B waited for A's row lock, then applied its update to the committed row. Nothing was lost. |

## Part B: the solution

### Rules added to the schema

[sql/01_rules.sql](sql/01_rules.sql) closes the three gaps listed in Portfolio 1's [Known limitations](../portfolio-1-database-design/README.md#known-limitations).

| Rule | How it is enforced |
|---|---|
| A frozen or closed wallet can't send money | Trigger `ledger_entries_apply` locks the wallet row and rejects a debit from a frozen wallet, or any entry on a closed wallet. Reversals are allowed, so finance can still return money. |
| `balance_kobo` always equals the ledger | The same trigger applies every ledger entry to the balance with a relative update. A wallet must start at 0, and `wallets_guard_balance_update` rejects any other change to the balance. Ledger entries are append-only (Portfolio 1), so balance = sum of entries at all times. |
| A request's amount matches its ledger entries | Deferred constraint triggers on `transfers`, `deposits` and `withdrawals` check the linked transaction's type, its two entries, the wallets and the amounts. View `v_request_ledger_mismatches` applies the same check to existing rows. |

`idempotency_keys` also gets a `transfer_id` column, so a retried request that failed returns the same failure.

### The transfer procedure

[sql/02_transfer.sql](sql/02_transfer.sql), `transfer(source, destination, amount_kobo, idempotency_key)`:

1. **Rejects malformed requests** with an error, such as a zero amount, an unknown wallet or a transfer to itself.
2. **Claims the idempotency key** with `INSERT ... ON CONFLICT DO NOTHING`. If the same request arrives twice at once, the second waits for the first to commit, then returns the stored result instead of posting again.
3. **Locks both wallets with `SELECT ... FOR UPDATE`, lowest `wallet_id` first.** Two transfers in opposite directions queue for the same first lock instead of deadlocking.
4. **Re-reads the locked wallets**, checks status and funds, and records the outcome. A business failure, such as insufficient funds, is stored as a `failed` transfer, not raised as an error, so the customer and support staff can see it.

### Tests

[tests/rule_tests.sql](tests/rule_tests.sql) runs **17 tests, all passing** ([evidence](evidence/rule-tests.txt)). Each one attempts an operation and checks the SQLSTATE and constraint that stopped it. The file also shows what `transfer()` returns for a normal transfer, a duplicate request, a frozen source, insufficient funds and a frozen destination. Finally it confirms that every existing row satisfies the new rules.

### Demonstrations

| File | Demonstrates | Outcome |
|---|---|---|
| [B1](evidence/b1_commit_rollback.txt) | **Commit, rollback, savepoint, atomicity** | A committed transfer is permanent. A rolled-back one leaves no ledger rows, transfer row or idempotency key, and session B never saw it. After an error, `ROLLBACK TO SAVEPOINT` kept the first transfer. A one-sided ledger posting failed at `COMMIT` (deferred trigger) and took a good transfer in the same transaction down with it. |
| [B2](evidence/b2_isolation_levels.txt) | **Isolation levels** | No dirty read, even at `READ UNCOMMITTED`. A non-repeatable read and a phantom happened at `READ COMMITTED`; neither happened at `REPEATABLE READ`. The cost: under `REPEATABLE READ`, `transfer()` failed with 40001 when its wallet had changed since the snapshot, and succeeded on retry. |
| [B3](evidence/b3_write_skew.txt) | **Write skew** | Rule: at least one finance officer must stay active. At `REPEATABLE READ`, two admins each deactivated a different officer, and both committed: none were left. At `SERIALIZABLE`, the second commit failed with 40001. At `READ COMMITTED` with `FOR UPDATE` on the check, B waited and then saw only one officer. |
| [B4](evidence/b4_locking.txt) | **Locks and deadlocks** | Locking in request order caused `deadlock detected` (40P01), and PostgreSQL aborted one session. Through `transfer()` the same pair simply queued. A row lock stopped a double spend: B waited, re-read the balance and failed with insufficient funds. An optimistic `version` check rejected a stale edit with `UPDATE 0`. `SKIP LOCKED` let two workers claim different withdrawals without waiting. |
| [B5](evidence/b5_crash_recovery.txt) | **Durability** | One transfer committed, another still open, then the server was killed with `SIGKILL`. On restart, PostgreSQL replayed its write-ahead log (`automatic recovery in progress ... redo done`). The committed transfer was there; the open one left nothing. Balances still matched the ledger. |

Every demo ends with a consistency check, and in Part B every one found 0 mismatches.

## Analysis

**Read committed with explicit row locks is the right default for transfers.** The rows that conflict are known in advance (two wallets), so locking them is cheap and exact. It gave the highest throughput, no retries and no deadlocks.

**Lock order matters for speed as well as correctness.** The naive code deadlocked 17 times in 15 seconds. Each deadlock froze two wallets until the 1-second `deadlock_timeout` expired, and other clients queued behind them. Cutting the timeout to 100 ms made the naive code 4 times faster, but it still lost money. Locking in `wallet_id` order removed deadlocks completely.

**SERIALIZABLE is a safety net, not free.** PostgreSQL's Serializable Snapshot Isolation detected every dangerous pattern, including write skew, which no row lock on the updated rows would catch. But every conflict becomes a rollback that the application must retry. On 20 hot wallets that meant 49–53% of transactions still failing after 10 tries. It fits rules that read many rows, like B3, more than hot single rows.

**Application retries are required above read committed.** SQLSTATE 40001 (serialization failure) and 40P01 (deadlock) mean "run the whole transaction again". The retry must restart from `BEGIN`, which is why it belongs in the application, not inside `transfer()`. The stress runs used pgbench's `--max-tries=10`.

**Unexpected finding.** In one earlier run of the naive SERIALIZABLE test, 2 of the 16 clients stopped with an internal PostgreSQL error: `new multixact has more than one updating member` ([extract](observed-internal-error.txt)). It did not recur in the final run. It matches an open report on the PostgreSQL hackers list: foreign-key checks take share locks on a row while other transactions update it and roll back ([patch proposal](https://www.postgresql.org/message-id/5778D6297D3CCF21+202609151836512678486@vastdata.com.cn), [reproducer](https://www.postgresql.org/message-id/f5a1d2fb96831f085de71288c66acfab%40evolution-digitale.fr)). The naive code matches that pattern: `ledger_entries` references `wallets`, and SERIALIZABLE aborts many transactions. It is recorded here as observed, not diagnosed further.

## Limitations

- **KYC daily and balance limits** are still not enforced. They would follow the same pattern: check them in `transfer()` while the source wallet is locked.
- **A superuser can still bypass the triggers**, for example with `session_replication_role = replica`, which Portfolio 2's data generator uses for speed. Production would use a less privileged application role.
- **Deposits and withdrawals have no procedure.** Only transfers do, although the new rules apply to all three.
- **The stress test is deliberately extreme.** 16 clients sharing 20 wallets is far more contention than real customers produce. It exposes problems quickly, but the throughput figures aren't a capacity estimate.

## Environment

PostgreSQL 16.15 in Docker (OrbStack, 8 CPUs, 4 GB), default settings except where a run says otherwise. `dblink` and `pgbench` ship with PostgreSQL.

## References

- PostgreSQL 16 documentation: [Transaction isolation](https://www.postgresql.org/docs/16/transaction-iso.html), [Explicit locking](https://www.postgresql.org/docs/16/explicit-locking.html), [SELECT ... FOR UPDATE and SKIP LOCKED](https://www.postgresql.org/docs/16/sql-select.html#SQL-FOR-UPDATE-SHARE), [Serialization failure handling](https://www.postgresql.org/docs/16/mvcc-serialization-failure-handling.html), [Write-ahead logging](https://www.postgresql.org/docs/16/wal-intro.html), [dblink](https://www.postgresql.org/docs/16/dblink.html), [pgbench](https://www.postgresql.org/docs/16/pgbench.html)
- Ports, D. R. K. and Grittner, K. (2012) 'Serializable Snapshot Isolation in PostgreSQL', *Proceedings of the VLDB Endowment*, 5(12), pp. 1850–1861.
