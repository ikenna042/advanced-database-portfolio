#!/usr/bin/env bash
# Portfolio 5, part 1: streaming replication, synchronous commit, failover and rejoin.
# Builds a fresh three-node cluster and writes ../evidence/r1 to r6. Takes about 3 minutes.
# Needs internet access once, to install tc (iproute2-tc) inside node2 for the delay test.
set -euo pipefail
cd "$(dirname "$0")"
EVIDENCE=../evidence
P1=../../portfolio-1-database-design/sql
P3=../../portfolio-3-transactions-concurrency

compose() { docker compose "$@"; }
# Runs SQL on a node, quietly, for values the script itself uses.
val() { compose exec -T "$1" psql -X -At -U kolaro -d kolaro -v ON_ERROR_STOP=1 -c "$2"; }
# q NODE SQL [PSQL_ARGS...]: prints "[NODE] SQL", then the result indented. An error is
# printed, not fatal. Extra arguments such as -v ids=... are passed to psql, so the SQL can
# refer to :'ids' without the printed statement growing.
q() {
  local node=$1 sql=$2; shift 2
  printf '[%s] %s\n' "$node" "$sql"
  printf '%s\n' "$sql" | compose exec -T "$node" psql -X -U kolaro -d kolaro -P footer=off "$@" 2>&1 \
    | sed -E 's/^psql:<stdin>:[0-9]+: //; s/^(.)/    \1/' || true
  echo
}
# app NODE_LIST SQL [ENV...]: runs SQL from the client container, as the application would.
app() {
  local hosts=$1 sql=$2; shift 2
  printf '[app -> %s%s] %s\n' "$hosts" "${*:+, $*}" "$sql"
  compose exec -T ${*/#/-e } client psql "host=$hosts dbname=kolaro user=kolaro target_session_attrs=read-write connect_timeout=2" \
    -X -P footer=off -c "$sql" 2>&1 | sed 's/^./    &/' || true
  echo
}
# Waits until a node accepts queries, for up to 2 minutes.
wait_ready() {
  for _ in $(seq 120); do
    compose exec -T "$1" psql -X -At -U kolaro -d kolaro -c "SELECT 1" > /dev/null 2>&1 && return 0
    sleep 1
  done
  echo "$1 did not become ready" >&2
  return 1
}
heading() { printf '\n== %s ==\n\n' "$*"; }
uptime_now() { compose exec -T client cut -d' ' -f1 /proc/uptime; }
balance_sql="SELECT wallet_number, balance_kobo FROM wallet.wallets WHERE wallet_number IN ('3100000001', '3100000002') ORDER BY 1"
replication_sql="SELECT application_name AS standby, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_not_yet_applied
  FROM pg_stat_replication ORDER BY 1"

mkdir -p "$EVIDENCE"
rm -f "$EVIDENCE"/r[0-9]_*.txt

# ---------------------------------------------------------------------------
echo "R1. Building a three-node cluster and loading the Kolaro schema on node1"
compose down -v --remove-orphans > /dev/null 2>&1
compose up -d --wait > /dev/null 2>&1
for file in $P1/01_schema.sql $P1/02_rules.sql $P1/03_views.sql $P1/04_sample_data.sql \
            $P3/sql/01_rules.sql $P3/sql/02_transfer.sql $P3/stress/setup.sql demo_wallets.sql; do
  compose exec -T node1 psql -X -q -U kolaro -d kolaro -v ON_ERROR_STOP=1 < "$file" > /dev/null 2>&1
done
val node1 "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (node2)'" > /dev/null
val node1 "SELECT pg_reload_conf()" > /dev/null
sleep 2
{
  heading "Nodes"
  echo "node1 was created with initdb. node2 and node3 were cloned from it with pg_basebackup"
  echo "and stream its write-ahead log (WAL). The schema and data were then loaded on node1 only."
  echo "synchronous_standby_names on node1 is 'FIRST 1 (node2)': a commit waits until node2 has"
  echo "the WAL on disk. node3 is asynchronous."
  echo
  for n in node1 node2 node3; do
    q $n "SELECT current_setting('cluster_name') AS node, version() ~ 'PostgreSQL 16' AS pg16,
                 CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END AS role"
  done
  heading "Replication as node1 sees it"
  q node1 "$replication_sql"
  q node1 "SELECT slot_name, slot_type, active FROM pg_replication_slots ORDER BY 1"
  heading "The data arrived on every node"
  for n in node1 node2 node3; do
    q $n "SELECT (SELECT count(*) FROM wallet.wallets) AS wallets, (SELECT count(*) FROM wallet.ledger_entries) AS ledger_entries,
                 (SELECT sum(balance_kobo) FROM wallet.wallets WHERE wallet_number LIKE '30%') AS stress_wallets_total_kobo"
  done
  heading "Standbys accept reads but refuse writes"
  q node2 "UPDATE wallet.wallets SET status = 'frozen' WHERE wallet_number = '3100000001'"
  q node3 "SELECT * FROM wallet.transfer('3100000001', '3100000002', 1000, 'r1-on-standby')"
  heading "A transfer committed on node1 is readable on both standbys"
  q node1 "SELECT transfer_id, status FROM wallet.transfer('3100000001', '3100000002', 250000, 'r1-transfer')"
  sleep 1
  for n in node1 node2 node3; do q $n "$balance_sql"; done
} > "$EVIDENCE/r1_setup.txt"

# ---------------------------------------------------------------------------
echo "R2. Replication lag and stale reads"
{
  heading "R2.1 Lag while node1 is busy: 8 clients sending transfers for 10 seconds"
  echo "Sampled once a second on node1. write/flush/replay lag is how long the standby took to"
  echo "write, flush and apply recent WAL. bytes_not_yet_applied is how far behind node1 it is."
  echo
  compose exec -T client pgbench -h node1 -U kolaro -n -c 8 -j 4 -T 10 -f /lab/safe.pgbench kolaro > /tmp/r2-pgbench.$$ 2>&1 &
  bench=$!
  sleep 1
  for i in 1 2 3 4 5 6 7 8; do
    val node1 "SELECT to_char(clock_timestamp(), 'HH24:MI:SS') || '  ' || string_agg(format('%s %s: write %s ms, flush %s ms, replay %s ms, %s bytes behind',
                        application_name, sync_state,
                        coalesce(round(extract(epoch FROM write_lag) * 1000, 2)::text, '-'),
                        coalesce(round(extract(epoch FROM flush_lag) * 1000, 2)::text, '-'),
                        coalesce(round(extract(epoch FROM replay_lag) * 1000, 2)::text, '-'),
                        pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), ' | ' ORDER BY application_name)
                 FROM pg_stat_replication"
    sleep 1
  done
  wait $bench
  echo
  grep -E '^(number of transactions actually|tps)' /tmp/r2-pgbench.$$
  rm -f /tmp/r2-pgbench.$$

  heading "R2.2 A stale read from an asynchronous standby"
  echo "node3's replay is paused to stand in for a slow or distant replica. It keeps receiving WAL."
  echo
  q node3 "SELECT pg_wal_replay_pause()"
  q node1 "SELECT transfer_id, status FROM wallet.transfer('3100000001', '3100000002', 500000, 'r2-stale-read')"
  sleep 1
  for n in node1 node2 node3; do q $n "$balance_sql"; done
  q node3 "SELECT pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS applied,
                  pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS bytes_received_not_applied,
                  now() - pg_last_xact_replay_timestamp() AS showing_data_as_of_this_long_ago"
  q node3 "SELECT pg_wal_replay_resume()"
  sleep 1
  q node3 "$balance_sql"

  heading "R2.3 Even the synchronous standby can serve a stale read"
  echo "synchronous_commit = on (the default) waits until node2 has flushed the WAL, not until it"
  echo "has applied it. With node2's replay paused, a commit on node1 still returns at once:"
  echo
  q node2 "SELECT pg_wal_replay_pause()"
  q node1 "SELECT transfer_id, status FROM wallet.transfer('3100000001', '3100000002', 100000, 'r2-sync-flush')"
  q node2 "$balance_sql"
  echo "synchronous_commit = remote_apply waits until node2 has applied it. The same kind of"
  echo "transfer now waits. After 3 seconds node2's replay is resumed:"
  echo
  compose exec -T -e PGOPTIONS="-c synchronous_commit=remote_apply" client psql -h node1 -U kolaro -d kolaro -X -P footer=off \
    -c "SELECT transfer_id, status FROM wallet.transfer('3100000001', '3100000002', 100000, 'r2-sync-apply')" \
    > /tmp/r2-apply.$$ 2>&1 &
  waiting=$!
  sleep 3
  q node1 "SELECT application_name, wait_event_type, wait_event, now() - xact_start AS waiting_for
             FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
  q node2 "SELECT pg_wal_replay_resume()"
  wait $waiting
  echo "[app -> node1, synchronous_commit=remote_apply] the waiting transfer returned:"
  sed 's/^./    &/' /tmp/r2-apply.$$
  rm -f /tmp/r2-apply.$$
  echo
  q node2 "$balance_sql"
} > "$EVIDENCE/r2_lag_and_stale_reads.txt"

# ---------------------------------------------------------------------------
echo "R3. What synchronous commit costs, with and without 10 ms of delay to node2"
bench_levels() {
  for level in off local remote_write on remote_apply; do
    compose exec -T -e PGOPTIONS="-c synchronous_commit=$level" client \
      pgbench -h node1 -U kolaro -n -c 1 -T 8 -f /lab/safe.pgbench kolaro 2>&1 \
      | awk -v net="$1" -v level="$level" '
          /^latency average/ {lat = $4}
          /^tps/ {tps = $3}
          END {printf "%-22s %-13s %9.0f %12.2f\n", net, level, tps, lat}'
  done
}
{
  heading "Commit cost by synchronous_commit level"
  echo "pgbench, 1 client for 8 seconds per row, running Portfolio 3's transfer() between the 20"
  echo "stress wallets. With one client nothing waits for locks, so the latency is the work plus"
  echo "the commit. node2 is the synchronous standby; node3 is asynchronous."
  echo
  echo "  off           commit returns before the WAL is flushed even on node1 (a crash can lose the last moments)"
  echo "  local         waits for node1's own disk only; standbys are not waited for"
  echo "  remote_write  also waits until node2 has received the WAL and handed it to its operating system"
  echo "  on            also waits until node2 has flushed it to disk (the default)"
  echo "  remote_apply  also waits until node2 has applied it, so a read on node2 sees the commit"
  echo
  compose exec -T node1 ping -c 5 -q node2 | tail -1 | sed 's/^/node1 -> node2 before: /'
  echo
  printf '%-22s %-13s %9s %12s\n' "network to node2" "level" "per second" "latency ms"
  bench_levels "same host"
  compose exec -T node2 sh -c 'apk add -q --no-cache iproute2-tc > /dev/null && tc qdisc add dev eth0 root netem delay 10ms'
  bench_levels "+10 ms (another zone)"
  echo
  compose exec -T node1 ping -c 5 -q node2 | tail -1 | sed 's/^/node1 -> node2 with delay: /'
  compose exec -T node2 tc qdisc del dev eth0 root
} > "$EVIDENCE/r3_commit_cost.txt" 2>&1

# ---------------------------------------------------------------------------
echo "R4. Availability when the synchronous standby fails"
{
  heading "R4.1 node2, the only synchronous standby, stops"
  compose stop node2 > /dev/null 2>&1
  echo "(docker compose stop node2)"
  echo
  q node1 "$replication_sql"
  echo "A transfer on node1 is sent in the background. It cannot finish committing, because no"
  echo "synchronous standby can confirm it."
  echo
  compose exec -T client psql -h node1 -U kolaro -d kolaro -X -P footer=off \
    -c "SELECT transfer_id, status FROM wallet.transfer('3100000001', '3100000002', 100000, 'r4-no-sync-standby')" \
    > /tmp/r4-wait.$$ 2>&1 &
  waiting=$!
  sleep 4
  q node1 "SELECT wait_event, now() - xact_start AS waiting_for, left(query, 40) AS query
             FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
  echo "Other sessions cannot see it yet:"
  echo
  q node1 "SELECT count(*) AS visible FROM wallet.idempotency_keys WHERE idempotency_key = 'r4-no-sync-standby'"
  echo "An operator (or a timeout in the application) cancels the wait:"
  echo
  q node1 "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
  wait $waiting || true
  echo "[app -> node1] the background transfer returned:"
  sed 's/^./    &/' /tmp/r4-wait.$$
  rm -f /tmp/r4-wait.$$
  echo
  echo "The client was told it succeeded, with a warning. The transfer is now visible on node1"
  echo "although no synchronous standby has confirmed it:"
  echo
  q node1 "SELECT count(*) AS visible FROM wallet.idempotency_keys WHERE idempotency_key = 'r4-no-sync-standby'"

  heading "R4.2 Quorum commit: any 1 of node2 and node3"
  q node1 "ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (node2, node3)'"
  q node1 "SELECT pg_reload_conf()"
  sleep 1
  q node1 "$replication_sql"
  q node1 "SELECT transfer_id, status FROM wallet.transfer('3100000001', '3100000002', 100000, 'r4-quorum')"

  heading "R4.3 node2 comes back and catches up from its replication slot"
  compose start node2 > /dev/null 2>&1
  echo "(docker compose start node2)"
  echo
  wait_ready node2
  sleep 2
  q node1 "$replication_sql"
  q node2 "SELECT idempotency_key FROM wallet.idempotency_keys WHERE idempotency_key LIKE 'r4-%' ORDER BY 1"
  q node1 "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (node2)'"
  q node1 "SELECT pg_reload_conf()"
} > "$EVIDENCE/r4_sync_availability.txt"

# ---------------------------------------------------------------------------
echo "R5. Failover: node1 is killed while the application is sending transfers"
NETWORK=kolaro-p5-replication_default
{
  heading "R5.1 Starting position"
  echo "node3 is disconnected from the network first, so it falls behind the way a distant"
  echo "asynchronous replica can. node2 stays the synchronous standby."
  echo
  docker network disconnect "$NETWORK" "$(compose ps -q node3)"
  echo "(docker network disconnect ... node3)"
  echo
  sleep 1
  compose exec -T client rm -f /tmp/app/stop
  compose exec -d client sh /lab/app.sh
  sleep 6
  q node1 "$replication_sql"

  heading "R5.2 node1 is killed"
  kill_time=$(uptime_now)
  compose kill node1 > /dev/null 2>&1
  echo "(docker compose kill node1, SIGKILL, at uptime ${kill_time} s)"
  echo
  echo "Failure detection: check node1 once a second; declare it failed after 3 misses in a row."
  echo "Each check is pg_isready with a 1-second timeout. The times are seconds since the kill."
  echo
  compose exec -T -e KILL="$kill_time" client sh -c '
    misses=0
    while [ $misses -lt 3 ]; do
      if out=$(pg_isready -h 172.28.50.11 -t 1 2>&1); then misses=0; else misses=$((misses + 1)); fi
      awk -v k="$KILL" -v o="$out" "{printf \"    check finished at +%.2f s: %s\n\", \$1 - k, o}" /proc/uptime
      sleep 1
    done'
  detect_time=$(uptime_now)
  echo "node1 declared failed."
  echo
  echo "[node2] SELECT pg_promote()"
  promote_time=$(compose exec -T client sh -c 'psql -h 172.28.50.12 -U kolaro -d kolaro -XAtq -c "SELECT pg_promote()" > /dev/null && cut -d" " -f1 /proc/uptime')
  echo "    promotion finished"
  echo
  sleep 6
  compose exec -T client touch /tmp/app/stop
  sleep 2
  compose exec -T client cat /tmp/app/acked.log > /tmp/r5-acked.$$
  compose exec -T client cat /tmp/app/errors.log > /tmp/r5-errors.$$
  q node2 "CHECKPOINT; SELECT pg_is_in_recovery() AS still_standby, timeline_id FROM pg_control_checkpoint()"
  echo "node2's log around the promotion:"
  compose logs --no-log-prefix node2 2>&1 | grep -E 'promote|selected new timeline|archive recovery complete|ready to accept' \
    | tail -4 | sed 's/^[0-9-]* [0-9:.]* UTC \[[0-9]*\] /    /'
  echo

  heading "R5.3 What the application saw"
  awk '{print $4}' /tmp/r5-acked.$$ | sort | uniq -c | awk '{printf "%6d transfers confirmed by %s\n", $1, $2}'
  echo "$(awk '$5 == "replayed"' /tmp/r5-acked.$$ | wc -l | tr -d ' ') transfers were confirmed as replayed (retried after committing)"
  echo "$(wc -l < /tmp/r5-errors.$$ | tr -d ' ') failed attempts, each retried with the same idempotency key. By error, in order:"
  sed -E 's/ \(172\.28\.50\.[0-9]+\)//' /tmp/r5-errors.$$ | awk -v k="$kill_time" '
    { t = $1; $1 = ""; msg = substr($0, 2)
      if (!(msg in n)) { order[++m] = msg; first[msg] = t }
      n[msg]++; last[msg] = t }
    END { for (i = 1; i <= m; i++) printf "    %3d x  +%.2f to +%.2f s  %s\n", n[order[i]], first[order[i]] - k, last[order[i]] - k, order[i] }' 
  echo
  last_node1=$(awk '$4 == "node1" {t = $1} END {print t}' /tmp/r5-acked.$$)
  first_node2=$(awk '$4 == "node2" {print $1; exit}' /tmp/r5-acked.$$)
  awk -v k="$kill_time" -v d="$detect_time" -v p="$promote_time" -v l="$last_node1" -v f="$first_node2" 'BEGIN {
    printf "Last confirmation from node1:        %+.2f s from the kill\n", l - k
    printf "node1 declared failed:               %+.2f s\n", d - k
    printf "node2 promoted:                      %+.2f s\n", p - k
    printf "First confirmation from node2:       %+.2f s   <- recovery time (RTO) for the application\n", f - k
  }'

  heading "R5.4 Was any confirmed transfer lost? (recovery point, RPO)"
  ids="{$(awk '$4 == "node1" {print $2}' /tmp/r5-acked.$$ | paste -sd, -)}"
  missing_sql="SELECT count(*) AS confirmed_by_node1, count(*) FILTER (WHERE t.transfer_id IS NULL) AS missing_here
                 FROM unnest(:'ids'::bigint[]) AS a(id) LEFT JOIN wallet.transfers t ON t.transfer_id = a.id"
  echo "Every transfer node1 confirmed before it died (their ids are passed in as :'ids'),"
  echo "looked up on the other nodes:"
  echo
  q node2 "$missing_sql" -v ids="$ids"
  echo "node3 is still a standby on the old timeline, and still disconnected, so it shows what would"
  echo "have been lost if it had been promoted instead:"
  echo
  q node3 "$missing_sql" -v ids="$ids"
  q node3 "SELECT pg_last_wal_replay_lsn() AS node3_applied_up_to, now() - pg_last_xact_replay_timestamp() AS behind_by"
  awk '$4 == "node1" {last = $2} $4 == "node2" && !first {first = $2}
       END {printf "Last transfer_id from node1: %s. First from node2: %s. Sequences are logged in batches of 32\nvalues, so a promoted standby skips the rest of the batch: ids have gaps but are never reused.\n", last, first}' /tmp/r5-acked.$$
  rm -f /tmp/r5-acked.$$ /tmp/r5-errors.$$
} > "$EVIDENCE/r5_failover.txt"

# ---------------------------------------------------------------------------
echo "R6. Rejoining node3 and the old primary"
{
  heading "R6.1 node3 follows the new primary"
  docker network connect --ip 172.28.50.13 "$NETWORK" "$(compose ps -q node3)"
  echo "(docker network connect ... node3)"
  echo
  q node2 "SELECT slot_name FROM pg_create_physical_replication_slot('node3', true)
           UNION ALL SELECT slot_name FROM pg_create_physical_replication_slot('node1', true)"
  q node3 "ALTER SYSTEM SET primary_conninfo = 'host=node2 user=replicator password=replicator-local-only'"
  q node3 "ALTER SYSTEM SET primary_slot_name = 'node3'"
  q node3 "SELECT pg_reload_conf()"
  sleep 4
  q node3 "SELECT sender_host, received_tli AS timeline, status FROM pg_stat_wal_receiver"
  ids_sql="SELECT count(*) AS transfers, max(transfer_id) AS highest_id FROM wallet.transfers"
  q node2 "$ids_sql"
  q node3 "$ids_sql"

  heading "R6.2 The old primary restarts: two primaries (split brain)"
  compose start node1 > /dev/null 2>&1
  echo "(docker compose start node1)"
  echo
  wait_ready node1
  q node1 "CHECKPOINT; SELECT current_setting('cluster_name') AS node, pg_is_in_recovery() AS is_standby, timeline_id FROM pg_control_checkpoint()"
  q node2 "CHECKPOINT; SELECT current_setting('cluster_name') AS node, pg_is_in_recovery() AS is_standby, timeline_id FROM pg_control_checkpoint()"
  echo "The application's connection string lists node1 first, and node1 accepts writes again:"
  echo
  app "node1,node2,node3" "SELECT current_setting('cluster_name') AS application_would_write_to"
  echo "A transfer sent to node1 now waits for its synchronous standby (node2), which no longer"
  echo "follows it. After 3 seconds it is cancelled, which leaves it committed on node1 alone:"
  echo
  compose exec -T client psql -h node1 -U kolaro -d kolaro -X -P footer=off \
    -c "SELECT transfer_id, status FROM wallet.transfer('3100000002', '3100000001', 700000, 'r6-split-brain')" > /tmp/r6-split.$$ 2>&1 &
  waiting=$!
  sleep 3
  val node1 "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep'" > /dev/null
  wait $waiting || true
  echo "[app -> node1] the transfer returned:"
  sed 's/^./    &/' /tmp/r6-split.$$
  rm -f /tmp/r6-split.$$
  echo
  split_sql="SELECT current_setting('cluster_name') AS node, (SELECT count(*) FROM wallet.idempotency_keys WHERE idempotency_key = 'r6-split-brain') AS split_brain_transfer,
                    (SELECT balance_kobo FROM wallet.wallets WHERE wallet_number = '3100000002') AS wallet_3100000002_kobo"
  q node1 "$split_sql"
  q node2 "$split_sql"

  heading "R6.3 Fencing node1 and rewinding it into a standby"
  compose stop node1 > /dev/null 2>&1
  echo "(docker compose stop node1)"
  echo
  echo "pg_rewind finds where node1's timeline split from node2's, and copies back from node2"
  echo "only the blocks that changed since then. node1's own changes after the split are discarded."
  echo
  compose run --rm --no-deps -T --entrypoint sh -u postgres node1 -c '
    pg_rewind --target-pgdata="$PGDATA" --source-server="host=node2 user=kolaro dbname=kolaro password=$POSTGRES_PASSWORD" --progress 2>&1
    touch "$PGDATA/standby.signal"
    printf "%s\n" "primary_conninfo = '\''host=node2 user=replicator password=$REPLICATION_PASSWORD'\''" \
                  "primary_slot_name = '\''node1'\''" >> "$PGDATA/postgresql.auto.conf"' \
    | tr '\r' '\n' | grep -vE 'kB \([0-9]+%\) copied|^$' | sed 's/^/    /'
  echo
  compose start node1 > /dev/null 2>&1
  wait_ready node1
  sleep 2
  q node1 "SELECT current_setting('cluster_name') AS node, pg_is_in_recovery() AS is_standby"
  q node1 "SELECT sender_host, received_tli AS timeline, status FROM pg_stat_wal_receiver"
  q node1 "$split_sql"

  heading "R6.4 The cluster after failover"
  q node2 "ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (node1, node3)'"
  q node2 "SELECT pg_reload_conf()"
  sleep 2
  q node2 "$replication_sql"
  echo "Every node holds identical data, and the Portfolio 3 consistency rules still hold:"
  echo
  for n in node1 node2 node3; do
    q $n "SELECT current_setting('cluster_name') AS node,
                 (SELECT count(*) FROM wallet.transfers) AS transfers,
                 (SELECT md5(string_agg(transfer_id || status, ',' ORDER BY transfer_id)) FROM wallet.transfers) AS transfers_checksum,
                 (SELECT sum(balance_kobo) FROM wallet.wallets WHERE wallet_number LIKE '30%') AS stress_wallets_kobo,
                 (SELECT sum(balance_kobo) FROM wallet.wallets WHERE wallet_number LIKE '31%') AS demo_wallets_kobo,
                 (SELECT count(*) FROM wallet.v_wallet_balance_audit WHERE difference_kobo <> 0) AS balance_mismatches,
                 (SELECT count(*) FROM wallet.v_request_ledger_mismatches) AS request_mismatches"
  done
} > "$EVIDENCE/r6_rejoin.txt"

echo "Replication evidence written to portfolio-5-distributed-cloud/evidence/r1 to r6"
