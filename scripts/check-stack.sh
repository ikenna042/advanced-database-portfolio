#!/usr/bin/env bash
# Confirms each database in the lab is up and answering real queries.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== Containers =="
docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'

echo
echo "== PostgreSQL =="
docker compose exec -T postgres psql -U kolaro -d kolaro -At -c "SELECT version();"
docker compose exec -T postgres psql -U kolaro -d kolaro -At \
  -c "SELECT 'pg_stat_statements ' || extversion FROM pg_extension WHERE extname = 'pg_stat_statements';"
docker compose exec -T postgres psql -U kolaro -d kolaro -At \
  -c "SELECT 'track_io_timing = ' || current_setting('track_io_timing');"

echo
echo "== MongoDB =="
docker compose exec -T mongo mongosh --quiet \
  -u kolaro -p "${MONGO_PASSWORD:-kolaro-local-only}" --authenticationDatabase admin \
  --eval "print('MongoDB ' + db.version() + ', ping ok = ' + db.adminCommand('ping').ok)"

echo
echo "== Redis =="
docker compose exec -T redis redis-cli INFO server | grep '^redis_version' | tr -d '\r'
docker compose exec -T redis redis-cli PING
