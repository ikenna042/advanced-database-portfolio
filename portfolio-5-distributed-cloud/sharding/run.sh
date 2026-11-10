#!/usr/bin/env bash
# Portfolio 5, part 2: sharding the Kolaro ledger with Citus.
# Builds a fresh Citus cluster, loads the Portfolio 2 data set from the main lab, and writes
# ../evidence/s1 to s6. Takes about 10 minutes, most of it the load and the shard moves,
# because the Citus image runs under emulation on Apple silicon.
# Needs the main lab's PostgreSQL running with the Portfolio 2 data set loaded.
set -euo pipefail
cd "$(dirname "$0")"
EVIDENCE=../evidence

compose() { docker compose "$@"; }
val() { compose exec -T coordinator psql -X -At -U kolaro -d kolaro -v ON_ERROR_STOP=1 -c "$1"; }
# q SQL [PSQL_ARGS...]: prints the SQL, then its result indented. Errors are printed, not fatal.
q() {
  local sql=$1; shift
  printf '[coordinator] %s\n' "$sql"
  printf '%s\n' "$sql" | compose exec -T coordinator psql -X -U kolaro -d kolaro -P footer=off "$@" 2>&1 \
    | sed -E 's/^psql:<stdin>:[0-9]+: //; s/^(.)/    \1/' || true
  echo
}
# Same query on the main lab's single PostgreSQL server, for comparison.
q_single() {
  printf '[single server] %s\n' "$1"
  printf '\\timing on\n%s\n' "$1" | docker compose -f ../../docker-compose.yml exec -T postgres psql -X -U kolaro -d kolaro -P footer=off 2>&1 \
    | sed -E 's/^(.)/    \1/' || true
  echo
}
# Waits until every node has finished the image's first-start setup (initdb, then a restart)
# and accepts queries with the citus extension installed.
wait_cluster() {
  local node
  for node in coordinator worker1 worker2 worker3; do
    for _ in $(seq 180); do
      if compose logs "$node" 2>&1 | grep -q 'PostgreSQL init process complete' \
         && compose exec -T "$node" psql -X -At -U kolaro -d kolaro -c "SELECT citus_version()" > /dev/null 2>&1; then
        continue 2
      fi
      sleep 1
    done
    echo "$node did not become ready" >&2
    return 1
  done
}
heading() { printf '\n== %s ==\n\n' "$*"; }
shards_per_node="SELECT nodename, count(*) AS shards, count(DISTINCT colocation_id) AS shard_groups,
       pg_size_pretty(sum(shard_size)) AS data
  FROM citus_shards WHERE citus_table_type = 'distributed' GROUP BY nodename ORDER BY nodename"
totals="SELECT (SELECT count(*) FROM wallet.ledger_entries) AS ledger_entries,
       (SELECT sum(amount_kobo) FROM wallet.ledger_entries) AS ledger_net_kobo,
       (SELECT sum(balance_kobo) FROM wallet.wallets) AS balances_kobo,
       (SELECT count(*) FROM wallet.transfers) AS transfers"

mkdir -p "$EVIDENCE"
rm -f "$EVIDENCE"/s[0-9]_*.txt

if [ "$(docker compose -f ../../docker-compose.yml exec -T postgres psql -X -At -U kolaro -d kolaro \
        -c "SELECT count(*) FROM wallet.ledger_entries" 2>/dev/null || echo 0)" -lt 4000000 ]; then
  echo "The main lab has no Portfolio 2 data. Run portfolio-2-query-optimisation/run.sh first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
echo "S1. Building the Citus cluster and loading the Portfolio 2 data set"
compose down -v --remove-orphans > /dev/null 2>&1
compose up -d --wait > /dev/null 2>&1
wait_cluster
val "SELECT citus_set_coordinator_host('coordinator')" > /dev/null
val "SELECT citus_add_node('worker1', 5432)" > /dev/null
val "SELECT citus_add_node('worker2', 5432)" > /dev/null
compose exec -T coordinator psql -X -q -U kolaro -d kolaro -v ON_ERROR_STOP=1 < sql/01_schema.sql > /dev/null
{
  heading "Cluster"
  q "SELECT citus_version()"
  q "SELECT nodename, groupid, noderole, shouldhaveshards FROM pg_dist_node ORDER BY nodeid"
  heading "Loading (COPY through the coordinator, which routes each row to its shard)"
  ./load.sh
  compose exec -T coordinator psql -X -q -U kolaro -d kolaro -v ON_ERROR_STOP=1 < sql/02_after_load.sql > /dev/null
  compose exec -T coordinator psql -X -q -U kolaro -d kolaro -v ON_ERROR_STOP=1 < sql/02_transfer.sql > /dev/null
  echo
  heading "Tables: how each one is spread"
  q "SELECT table_name, citus_table_type, distribution_column, colocation_id, shard_count, table_size
       FROM citus_tables ORDER BY colocation_id, table_name"
  heading "Shards per worker (32 shards per distributed table)"
  q "$shards_per_node"
  heading "Rows per worker for ledger_entries"
  q "SELECT nodename, count(*) AS shards, sum(rows) AS ledger_entries
       FROM (SELECT shardid, nodename, (result::bigint) AS rows
               FROM run_command_on_shards('wallet.ledger_entries', 'SELECT count(*) FROM %s') r
               JOIN citus_shards USING (shardid)) s
      GROUP BY nodename ORDER BY nodename"
  heading "The same totals as the single server"
  q "$totals"
  q_single "$totals"
  heading "Uniqueness that does not include the shard key cannot be enforced"
  q "ALTER TABLE wallet.customers ADD CONSTRAINT customers_phone_unique UNIQUE (phone)"
  q "ALTER TABLE wallet.wallets ADD CONSTRAINT wallets_number_unique UNIQUE (wallet_number)"
} > "$EVIDENCE/s1_cluster.txt" 2>&1

# ---------------------------------------------------------------------------
echo "S2. Router queries and fan-out queries"
statement="SELECT created_at, amount_kobo FROM wallet.ledger_entries WHERE wallet_id = 50000 ORDER BY created_at DESC LIMIT 50"
monthly="SELECT date_trunc('month', created_at) AS month, count(*) AS entries, sum(amount_kobo) FILTER (WHERE amount_kobo > 0) AS credited_kobo
           FROM wallet.ledger_entries GROUP BY 1 ORDER BY 1"
{
  heading "S2.1 A customer statement: one wallet, so one shard"
  q "SELECT wallet_id, shardid, nodename FROM wallet.wallet_placement WHERE wallet_id = 50000"
  q "EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF) $statement"
  q "\\timing on
$statement" -o /dev/null
  heading "S2.2 Monthly volumes: every shard, in parallel"
  q "EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF) $monthly"
  q "\\timing on
$monthly"
  q_single "$monthly"
} > "$EVIDENCE/s2_router_and_fanout.txt" 2>&1

# ---------------------------------------------------------------------------
echo "S3. Joins: co-located, reference and repartition"
audit="SELECT count(*) AS wallets, count(*) FILTER (WHERE w.balance_kobo <> l.total) AS balance_mismatches
         FROM wallet.wallets w JOIN (SELECT wallet_id, sum(amount_kobo) AS total FROM wallet.ledger_entries GROUP BY wallet_id) l USING (wallet_id)"
by_category="SELECT m.category, count(*) AS payments, sum(e.amount_kobo) AS received_kobo
               FROM wallet.ledger_entries e JOIN wallet.wallets w USING (wallet_id) JOIN wallet.merchants m USING (merchant_id)
              WHERE e.amount_kobo > 0 AND e.created_at >= '2026-10-01' AND e.created_at < '2026-11-01'
              GROUP BY 1 ORDER BY 3 DESC"
by_type="SELECT t.txn_type, count(*) AS entries
           FROM wallet.ledger_entries e JOIN wallet.ledger_transactions t USING (transaction_id)
          WHERE e.created_at >= '2026-10-01' AND e.created_at < '2026-11-01'
          GROUP BY 1 ORDER BY 1"
{
  heading "S3.1 Co-located join: balance audit (wallets with ledger_entries, both sharded on wallet_id)"
  echo "Each worker joins its own wallet shards with the matching entry shards. Nothing moves"
  echo "between workers except the per-shard counts."
  echo
  q "EXPLAIN (COSTS OFF) $audit"
  q "\\timing on
$audit"
  heading "S3.2 Join with a reference table: October merchant takings by category"
  q "\\timing on
$by_category"
  heading "S3.3 Join on a column that is not the shard key: entries with their transactions"
  echo "ledger_entries is sharded on wallet_id and ledger_transactions on transaction_id, so"
  echo "matching rows are on different workers."
  echo
  q "$by_type"
  echo "Allowing Citus to re-shard both sides on transaction_id for this query (a repartition join):"
  echo
  q "SET citus.enable_repartition_joins = on;
\\timing on
$by_type"
  q_single "$by_type"
} > "$EVIDENCE/s3_joins.txt" 2>&1

# ---------------------------------------------------------------------------
echo "S4. Transfers that span shards: two-phase commit"
# Demo wallets with plenty of money: two in the same shard, and two on different workers.
read -r same_a same_b <<< "$(val "SELECT min(wallet_id), max(wallet_id) FROM (
    SELECT wallet_id, shardid FROM wallet.wallet_placement WHERE balance_kobo > 5000000 AND wallet_id > 3) p
  WHERE shardid = (SELECT shardid FROM wallet.wallet_placement WHERE balance_kobo > 5000000 AND wallet_id > 3
                    GROUP BY shardid ORDER BY count(*) DESC LIMIT 1)" | tr '|' ' ')"
read -r cross_a cross_b <<< "$(val "SELECT (SELECT min(wallet_id) FROM wallet.wallet_placement WHERE nodename = 'worker1' AND balance_kobo > 5000000 AND wallet_id > 3),
                                          (SELECT min(wallet_id) FROM wallet.wallet_placement WHERE nodename = 'worker2' AND balance_kobo > 5000000 AND wallet_id > 3)" | tr '|' ' ')"
pair_balances() { echo "SELECT wallet_id, balance_kobo, nodename FROM wallet.wallet_placement WHERE wallet_id IN ($1, $2) ORDER BY 1"; }
{
  heading "S4.1 Both wallets in the same shard"
  q "$(pair_balances "$same_a" "$same_b")"
  echo "citus.log_remote_commands shows every command the coordinator sends to a worker:"
  echo
  q "SET citus.log_remote_commands = on;
SELECT wallet.transfer_by_id($same_a, $same_b, 1000)" > /tmp/s4-same.$$
  cat /tmp/s4-same.$$
  servers=$(grep -o 'on server kolaro@worker[0-9]' /tmp/s4-same.$$ | sort -u | wc -l | tr -d ' ')
  if [ "$servers" -gt 1 ]; then
    echo "Both wallets are in one shard, yet $servers workers took part and the commit used PREPARE"
    echo "TRANSACTION: the ledger_transactions row is placed by its own transaction_id, and this"
    echo "one went to another worker. With that table sharded separately, almost every transfer"
    echo "needs two-phase commit. Adding the source wallet_id to ledger_transactions and"
    echo "co-locating it with wallets would keep a same-shard transfer on one worker."
  else
    echo "Both wallets and the new ledger_transactions row were on one worker, so Citus committed"
    echo "with a plain COMMIT: no two-phase commit was needed."
  fi
  rm -f /tmp/s4-same.$$
  heading "S4.2 Wallets on different workers"
  q "$(pair_balances "$cross_a" "$cross_b")"
  q "SET citus.log_remote_commands = on;
SELECT wallet.transfer_by_id($cross_a, $cross_b, 1000)"
  echo "PREPARE TRANSACTION asks each worker to make its part durable and promise it can commit."
  echo "Only when every worker has prepared does the coordinator send COMMIT PREPARED. Citus"
  echo "records the decision in pg_dist_transaction, so if the coordinator fails in between, a"
  echo "recovery process can finish or roll back the prepared transactions."
  heading "S4.3 Atomicity across workers"
  echo "Credit the worker2 wallet first, then debit the worker1 wallet by more than it holds:"
  echo
  q "BEGIN;
UPDATE wallet.wallets SET balance_kobo = balance_kobo + 999999999999 WHERE wallet_id = $cross_b;
UPDATE wallet.wallets SET balance_kobo = balance_kobo - 999999999999 WHERE wallet_id = $cross_a;
COMMIT;"
  q "$(pair_balances "$cross_a" "$cross_b")"
  echo "Neither change was kept: the credit on worker2 was rolled back with the failed debit on worker1."
  heading "S4.4 How many real transfers would span shards?"
  q "WITH oct AS MATERIALIZED (
       SELECT source_wallet_id, destination_wallet_id FROM wallet.transfers
        WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01'),
     placed AS (
       SELECT s.shardid AS src_shard, d.shardid AS dst_shard, s.nodename AS src_node, d.nodename AS dst_node
         FROM oct
         JOIN wallet.wallet_placement s ON s.wallet_id = oct.source_wallet_id
         JOIN wallet.wallet_placement d ON d.wallet_id = oct.destination_wallet_id)
     SELECT count(*) AS october_transfers,
            round(100.0 * count(*) FILTER (WHERE src_shard = dst_shard) / count(*), 1) AS pct_same_shard,
            round(100.0 * count(*) FILTER (WHERE src_shard <> dst_shard AND src_node = dst_node) / count(*), 1) AS pct_same_worker,
            round(100.0 * count(*) FILTER (WHERE src_node <> dst_node) / count(*), 1) AS pct_different_workers
       FROM placed"
  heading "S4.5 Throughput: same-shard transfers compared with cross-worker transfers"
  echo "pgbench, 4 clients for 15 seconds each, transfers of 1 kobo between 200 wallet pairs of each"
  echo "kind. No wallet appears in more than one pair, so clients rarely wait for each other's locks."
  echo
  val "CREATE TABLE IF NOT EXISTS public.bench_pairs (kind text, i int, src bigint, dst bigint)" > /dev/null
  val "TRUNCATE public.bench_pairs" > /dev/null
  val "INSERT INTO public.bench_pairs
       WITH w AS (SELECT wallet_id, shardid, row_number() OVER (PARTITION BY shardid ORDER BY wallet_id) AS n
                    FROM wallet.wallet_placement WHERE balance_kobo > 5000000 AND wallet_id > 3)
       SELECT 'same_shard', row_number() OVER (), a.wallet_id, b.wallet_id
         FROM w a JOIN w b ON a.shardid = b.shardid AND b.n = a.n + 1
        WHERE a.n % 2 = 1
        LIMIT 200" > /dev/null
  val "INSERT INTO public.bench_pairs
       SELECT 'cross_worker', row_number() OVER (), a.wallet_id, b.wallet_id
         FROM (SELECT wallet_id, row_number() OVER (ORDER BY wallet_id) AS n FROM wallet.wallet_placement WHERE nodename = 'worker1' AND balance_kobo > 5000000 AND wallet_id > 3) a
         JOIN (SELECT wallet_id, row_number() OVER (ORDER BY wallet_id) AS n FROM wallet.wallet_placement WHERE nodename = 'worker2' AND balance_kobo > 5000000 AND wallet_id > 3) b USING (n)
        LIMIT 200" > /dev/null
  for kind in same_shard cross_worker; do
    printf '%s\n' "\\set i random(1, 200)" \
      "SELECT src, dst FROM public.bench_pairs WHERE kind = '$kind' AND i = :i \\gset" \
      "SELECT wallet.transfer_by_id(:src, :dst, 1);" \
      | compose exec -T coordinator sh -c "cat > /tmp/$kind.pgbench"
    compose exec -T coordinator pgbench -U kolaro -n -c 4 -j 4 -T 15 -f "/tmp/$kind.pgbench" kolaro 2>&1 \
      | awk -v kind="$kind" '/^latency average/ {lat = $4} /^tps/ {tps = $3}
                             END {printf "%-13s %8.1f transfers per second, %7.1f ms average latency\n", kind, tps, lat}'
  done
  echo
  q "SELECT count(*) AS prepared_transactions_left_over FROM pg_prepared_xacts"
} > "$EVIDENCE/s4_distributed_transactions.txt" 2>&1

# ---------------------------------------------------------------------------
echo "S5. A worker fails"
w1=$(val "SELECT min(wallet_id) FROM wallet.wallet_placement WHERE nodename = 'worker1' AND balance_kobo > 5000000 AND wallet_id > 3")
w2=$(val "SELECT min(wallet_id) FROM wallet.wallet_placement WHERE nodename = 'worker2' AND balance_kobo > 5000000 AND wallet_id > 3")
read -r t1 t2 <<< "$(val "SELECT min(wallet_id), max(wallet_id) FROM (SELECT wallet_id FROM wallet.wallet_placement
                           WHERE nodename = 'worker1' AND balance_kobo > 5000000 AND wallet_id > 3 ORDER BY wallet_id LIMIT 2) x" | tr '|' ' ')"
{
  heading "S5.1 worker2 stops"
  compose stop worker2 > /dev/null 2>&1
  echo "(docker compose stop worker2)"
  echo
  q "SELECT count(*) AS entries_for_wallet_on_worker1 FROM wallet.ledger_entries WHERE wallet_id = $w1"
  q "SELECT count(*) AS entries_for_wallet_on_worker2 FROM wallet.ledger_entries WHERE wallet_id = $w2"
  q "SELECT count(*) AS all_entries FROM wallet.ledger_entries"
  echo "Five transfers between two wallets that are both on worker1 ($t1 and $t2). The"
  echo "ledger_transactions row for each one goes to the shard that owns its new transaction_id,"
  echo "which may be on worker2:"
  echo
  for i in 1 2 3 4 5; do
    q "SELECT wallet.transfer_by_id($t1, $t2, 100)"
  done
  heading "S5.2 worker2 restarts"
  compose start worker2 > /dev/null 2>&1
  compose exec -T worker2 sh -c 'until pg_isready -q -U kolaro; do sleep 1; done'
  echo "(docker compose start worker2)"
  echo
  q "SELECT count(*) AS all_entries FROM wallet.ledger_entries"
} > "$EVIDENCE/s5_worker_failure.txt" 2>&1

# ---------------------------------------------------------------------------
echo "S6. Adding worker3 and rebalancing while transfers continue"
{
  heading "S6.1 Before"
  q "$shards_per_node"
  q "$totals"
  heading "S6.2 Add worker3 and move shards to it, online"
  q "SELECT citus_add_node('worker3', 5432)"
  echo "While the shards move, 4 pgbench clients keep sending cross-worker transfers."
  echo
  # pgbench runs in 5-second rounds until the rebalance has finished.
  rm -f /tmp/s6-stop.$$
  ( while [ ! -f /tmp/s6-stop.$$ ]; do
      compose exec -T coordinator pgbench -U kolaro -n -c 4 -j 4 -T 5 -f /tmp/cross_worker.pgbench kolaro 2>&1 || true
    done ) > /tmp/s6-bench.$$ &
  bench=$!
  sleep 3
  start=$(date +%s)
  q "SELECT citus_rebalance_start(shard_transfer_mode => 'force_logical')"
  q "SELECT citus_rebalance_wait()"
  echo "Rebalance took $(( $(date +%s) - start )) seconds."
  echo
  touch /tmp/s6-stop.$$
  wait $bench || true
  awk '/^number of transactions actually processed/ {ok += $6} /^number of failed transactions/ {failed += $5}
       /^pgbench: error/ {errors++; if (!seen[$0]++) msgs[++m] = $0} /^tps/ {rounds++}
       END {printf "pgbench during the rebalance: %d rounds of 5 s, %d transfers committed, %d failed, %d client errors\n", rounds, ok, failed, errors
            for (i = 1; i <= m && i <= 5; i++) print "    " msgs[i]}' /tmp/s6-bench.$$
  rm -f /tmp/s6-bench.$$ /tmp/s6-stop.$$
  echo
  heading "S6.3 After"
  q "$shards_per_node"
  echo "The totals changed only by the transfers made during the move (1 kobo each, so the"
  echo "ledger still nets to the same amount and every balance still matches its entries):"
  echo
  q "$totals"
  q "$audit"
} > "$EVIDENCE/s6_rebalance.txt" 2>&1

echo "Sharding evidence written to portfolio-5-distributed-cloud/evidence/s1 to s6"
