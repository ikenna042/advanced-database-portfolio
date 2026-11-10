#!/usr/bin/env bash
# Reproduces all of Portfolio 5 and rewrites the evidence folder. Takes about 15 minutes.
#   1. replication/run.sh: three PostgreSQL nodes; lag, synchronous commit, failover, rejoin.
#   2. sharding/run.sh: a Citus cluster loaded from the main lab's Portfolio 2 data set.
# Each part runs as its own Docker Compose project and is stopped when it finishes, so the
# two clusters never compete for the machine. Their data volumes are kept until the next run.
set -euo pipefail
cd "$(dirname "$0")"

./replication/run.sh
(cd replication && docker compose stop > /dev/null 2>&1)

./sharding/run.sh
(cd sharding && docker compose stop > /dev/null 2>&1)

echo "Done. Evidence is in portfolio-5-distributed-cloud/evidence/"
