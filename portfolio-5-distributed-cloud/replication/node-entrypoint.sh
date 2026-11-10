#!/bin/sh
# Starts one node of the replication lab. $1 is the node name.
#  - node1 with an empty data directory: the image's normal initdb, then init-primary.sh.
#  - node2/node3 with an empty data directory: clone node1 with pg_basebackup. -R writes
#    standby.signal and primary_conninfo, so the clone starts as a streaming standby.
#    -C -S creates a replication slot on node1 named after this node, so node1 keeps
#    the WAL this standby still needs.
#  - Any node with existing data: start it as it is. Whether it runs as a primary or a
#    standby depends on whether standby.signal is present.
set -eu
NODE=$1

if [ "$NODE" != node1 ] && [ ! -s "$PGDATA/PG_VERSION" ]; then
  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"
  until pg_isready -q -h node1 -U kolaro; do sleep 1; done
  PGPASSWORD=$REPLICATION_PASSWORD su-exec postgres \
    pg_basebackup -h node1 -U replicator -D "$PGDATA" -R -X stream -C -S "$NODE" -c fast
fi

# cluster_name becomes this node's application_name when it streams from a primary,
# which is the name synchronous_standby_names refers to.
# wal_log_hints lets pg_rewind resynchronise a failed primary later.
exec docker-entrypoint.sh postgres \
  -c cluster_name="$NODE" \
  -c wal_log_hints=on \
  -c wal_keep_size=512MB \
  -c hot_standby_feedback=on
