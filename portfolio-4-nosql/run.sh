#!/usr/bin/env bash
# Reproduces all of Portfolio 4 and rewrites the evidence folder. Takes about 4 minutes.
# Rebuilds the PostgreSQL data (Portfolios 1-3), loads MongoDB from it, then runs the
# MongoDB and Redis demonstrations. The MongoDB "kolaro" database and all Redis keys are replaced.
set -euo pipefail

cd "$(dirname "$0")"
compose() { docker compose -f ../docker-compose.yml "$@"; }
psql() { compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U kolaro -d kolaro "$@"; }
MONGO_AUTH=(-u kolaro -p "${MONGO_PASSWORD:-kolaro-local-only}" --authenticationDatabase admin)
# Copies a script into the container and runs it. Extra arguments go before --file.
mongosh_file() {
  compose exec -T mongo sh -c "cat > /tmp/$(basename "$1")" < "$1"
  compose exec -T mongo mongosh --quiet "${MONGO_AUTH[@]}" "${@:2}" --file "/tmp/$(basename "$1")"
}

rm -rf evidence
mkdir -p evidence

echo "1. Rebuilding PostgreSQL: Portfolio 1 schema, Portfolio 2 data, Portfolio 3 procedure"
../portfolio-1-database-design/run.sh > /dev/null
psql < ../portfolio-2-query-optimisation/seed/seed.sql > /dev/null 2>&1
psql < ../portfolio-3-transactions-concurrency/sql/01_rules.sql
psql < ../portfolio-3-transactions-concurrency/sql/02_transfer.sql

echo "2. Creating MongoDB collections and loading them from PostgreSQL"
{
  mongosh_file mongo/01_collections.js
  for pair in customers:customers statements:statements transfers:transfer_edges; do
    start=$(date +%s)
    cat export/_dates.sql "export/${pair%%:*}.sql" | psql -At \
      | compose exec -T mongo mongoimport "${MONGO_AUTH[@]}" --db kolaro --collection "${pair##*:}" \
          --numInsertionWorkers 4 --stopOnError 2>&1 | grep -v 'connected to'
    echo "${pair##*:}: loaded in $(( $(date +%s) - start )) s"
  done
  echo
  echo "== Row counts in PostgreSQL compared with document counts in MongoDB =="
  pg=$(psql -At -c "SELECT
      (SELECT count(*) FROM wallet.customers),
      (SELECT count(*) FROM wallet.ledger_entries e JOIN wallet.wallets w USING (wallet_id)
        WHERE w.wallet_type <> 'system'
          AND e.created_at >= '2026-08-01 00:00+00' AND e.created_at < '2026-11-01 00:00+00'),
      (SELECT count(*) FROM wallet.transfers WHERE status = 'completed'
          AND created_at >= '2026-10-01 00:00+00' AND created_at < '2026-11-01 00:00+00')" | tr '|' ' ')
  compose exec -T mongo mongosh --quiet "${MONGO_AUTH[@]}" kolaro --eval "
    const pg = '$pg'.split(' ').map(Number);
    const mongo = [db.customers.countDocuments(),
                   db.statements.aggregate([{\$group: {_id: null, n: {\$sum: '\$entry_count'}}}]).toArray()[0].n,
                   db.transfer_edges.countDocuments()];
    ['customers', 'statement entries (Aug-Oct 2026)', 'completed transfers (Oct 2026)'].forEach((name, i) =>
      print(name.padEnd(34) + 'PostgreSQL ' + String(pg[i]).padStart(8) + '   MongoDB ' + String(mongo[i]).padStart(8) +
            (pg[i] === mongo[i] ? '   match' : '   DIFFERENT')));
    print();
    for (const c of ['customers', 'statements', 'transfer_edges']) {
      const s = db[c].stats();
      print(c.padEnd(16) + String(s.count).padStart(8) + ' documents, ' + (s.size / 1048576).toFixed(1) + ' MB of BSON, ' +
            (s.storageSize / 1048576).toFixed(1) + ' MB on disk after compression, average ' + s.avgObjSize + ' bytes');
    }
    printjson(db.statements.aggregate([{\$group: {_id: null, buckets: {\$sum: 1}, largest_bucket_entries: {\$max: '\$entry_count'},
                                                  largest_bucket_bytes: {\$max: {\$bsonSize: '\$\$ROOT'}}}}, {\$project: {_id: 0}}]).toArray()[0]);
    print('One customer document:');
    printjson(db.customers.findOne({_id: 2}));
    print('One statement bucket, first 2 of its entries:');
    printjson(db.statements.findOne({wallet_number: '1100000001', month: '2026-10'}, {entries: {\$slice: 2}}));"
  echo
  mongosh_file mongo/02_audit_events.js
} > evidence/load.txt 2>&1
grep -q DIFFERENT evidence/load.txt && { echo "PostgreSQL and MongoDB counts differ. See evidence/load.txt" >&2; exit 1; }

echo "3. MongoDB queries without secondary indexes"
mongosh_file mongo/04_queries.js --eval "var phase = 'baseline'" > evidence/queries-baseline.txt 2>&1

echo "4. Building indexes and running the queries again"
mongosh_file mongo/03_indexes.js > evidence/indexes.txt 2>&1
mongosh_file mongo/04_queries.js --eval "var phase = 'indexed'" > evidence/queries-indexed.txt 2>&1

echo "5. Validation and embedded updates"
mongosh_file mongo/05_writes.js > evidence/writes.txt 2>&1

echo "6. Concurrent spending-limit test: 10 workers x 5 requests, naive and atomic"
compose exec -T mongo sh -c 'cat > /tmp/worker.js' < mongo/06_daily_spend_worker.js
{
  echo "Daily limit N50,000 (5,000,000 kobo). 50 requests of N2,000 each, from 10 workers at once."
  echo "At most 25 can be approved."
  for mode in naive atomic; do
    compose exec -T mongo mongosh --quiet "${MONGO_AUTH[@]}" kolaro --eval \
      "db.daily_spend.replaceOne({_id: 'limit-test:$mode'}, {limit_kobo: 5000000, spent_kobo: 0, approved: []}, {upsert: true})" > /dev/null
    for worker in $(seq 1 10); do
      compose exec -T mongo mongosh --quiet "${MONGO_AUTH[@]}" \
        --eval "var mode = '$mode', worker = $worker" --file /tmp/worker.js &
    done
    wait
    compose exec -T mongo mongosh --quiet "${MONGO_AUTH[@]}" kolaro --eval "
      const d = db.daily_spend.findOne({_id: 'limit-test:$mode'});
      print();
      print('== $mode ==');
      print('requests approved:           ' + d.approved.length);
      print('money actually approved:     ' + d.approved.length * 200000 + ' kobo');
      print('spent_kobo stored on record: ' + d.spent_kobo + ' kobo');
      print('over the daily limit by:     ' + Math.max(0, d.approved.length * 200000 - d.limit_kobo) + ' kobo');
      print('record understates spending: ' + (d.approved.length * 200000 - d.spent_kobo) + ' kobo');"
  done
} > evidence/daily-spend-concurrency.txt 2>&1

echo "7. Redis patterns"
./redis/demo.sh > evidence/redis.txt 2>&1

echo "Done. Evidence is in portfolio-4-nosql/evidence/"
