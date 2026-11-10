#!/bin/sh
# Plays the Kolaro application during the failover demo. It sends one transfer at a time
# between the 20 stress-test wallets and logs every attempt with the time it finished.
#   /tmp/app/acked.log   transfers the database confirmed: time, transfer_id, status, node
#   /tmp/app/errors.log  attempts that failed: time and the first line of the error
# Time is seconds since the machine booted (/proc/uptime), which every container shares,
# so run.sh can compare it with the moment it killed the primary.
# The connection string lists all three nodes with target_session_attrs=read-write:
# libpq tries them in order and uses the first one that accepts writes, so after a
# failover the application finds the new primary without being reconfigured.
# Stops when /tmp/app/stop exists.
mkdir -p /tmp/app
: > /tmp/app/acked.log
: > /tmp/app/errors.log
CONN="host=node1,node2,node3 hostaddr=172.28.50.11,172.28.50.12,172.28.50.13 dbname=kolaro user=kolaro target_session_attrs=read-write connect_timeout=1"
now() { cut -d' ' -f1 /proc/uptime; }
# A failed attempt is retried with the same request and idempotency key, so a transfer that
# committed just before the primary died is returned as replayed instead of being posted twice.
pick() {
  src=$((RANDOM % 20))
  dst=$(( (src + 1 + RANDOM % 19) % 20 ))
  amount=$((100 + RANDOM % 5000))
}
i=1
pick
while [ ! -f /tmp/app/stop ]; do
  if out=$(psql "$CONN" -XAtq -v ON_ERROR_STOP=1 -F ' ' -c "
        SELECT transfer_id, status, current_setting('cluster_name'), CASE WHEN replayed THEN 'replayed' ELSE 'new' END
          FROM wallet.transfer('30' || lpad('$((src + 1))', 8, '0'), '30' || lpad('$((dst + 1))', 8, '0'),
                               $amount, 'failover-app-$i')" 2>&1); then
    echo "$(now) $out" >> /tmp/app/acked.log
    i=$((i + 1))
    pick
  else
    echo "$(now) $(echo "$out" | head -1)" >> /tmp/app/errors.log
    sleep 0.1
  fi
done
