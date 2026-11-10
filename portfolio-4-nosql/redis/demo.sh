#!/usr/bin/env bash
# Redis key-value patterns for Kolaro Wallet. Run by ../run.sh; prints the evidence.
# Assumes PostgreSQL has the Portfolio 2 data and the Portfolio 3 transfer procedure.
set -euo pipefail
cd "$(dirname "$0")"
compose() { docker compose -f ../../docker-compose.yml "$@"; }
r() { compose exec -T redis redis-cli "$@"; }
pg() { compose exec -T postgres psql -X -At -U kolaro -d kolaro -c "$1"; }

r FLUSHALL > /dev/null
echo "Redis $(r INFO server | grep '^redis_version' | cut -d: -f2 | tr -d '\r')"

echo
echo "=== R1  Idempotency: 20 copies of one request arrive at the same moment ==="
echo "Each copy runs: SET idem:<customer>:<key> processing NX EX 86400"
echo "NX means 'only if the key does not exist', so exactly one copy can claim it."
for i in $(seq 1 20); do
  r SET idem:4:pay-7f3a processing NX EX 86400 > "/tmp/kolaro-idem-$i" &
done
wait
echo "Copies that got OK (and would go on to post the transfer): $(grep -l '^OK' /tmp/kolaro-idem-* | wc -l | tr -d ' ')"
echo "Copies that got nil (and would wait for the stored result): $(grep -L '^OK' /tmp/kolaro-idem-* | wc -l | tr -d ' ')"
rm -f /tmp/kolaro-idem-*
echo "The winner stores the result, keeping the 24-hour expiry (KEEPTTL):"
r SET idem:4:pay-7f3a '{"status":"completed"}' XX KEEPTTL
r GET idem:4:pay-7f3a
echo "Seconds until Redis forgets the key: $(r TTL idem:4:pay-7f3a)"
echo "PostgreSQL's idempotency_keys table stays the durable record; Redis is the fast first check."

echo
echo "=== R2  Rate limiting PIN attempts: at most 5 in any 60 seconds ==="
echo "Fixed window with INCR + EXPIRE, the simplest version:"
for i in $(seq 1 7); do
  n=$(r INCR pin:fixed:4:2026-11-10T09:15)
  [ "$n" -eq 1 ] && r EXPIRE pin:fixed:4:2026-11-10T09:15 60 > /dev/null
  [ "$n" -le 5 ] && verdict=allowed || verdict=BLOCKED
  echo "  attempt $i: count $n, $verdict"
done
echo "A fixed window resets on the minute, so 5 attempts at 09:15:59 and 5 more at 09:16:00 all pass."
echo "Sliding window with a sorted set, in one atomic Lua script (sliding_window.lua):"
compose exec -T redis sh -c 'cat > /tmp/sliding_window.lua' < sliding_window.lua
now=1793000000000   # a fixed clock in milliseconds, so the output is repeatable
for t in 0 5000 10000 15000 20000 25000 30000 61000 62000; do
  out=$(compose exec -T redis redis-cli --eval /tmp/sliding_window.lua pin:sliding:4 , $((now + t)) 60000 5 "a$t" | tr '\n' ' ')
  set -- $out
  [ "$1" = "1" ] && verdict=allowed || verdict=BLOCKED
  echo "  attempt at +$((t / 1000))s: $verdict (attempts in the last 60 s: $2)"
done
echo "At +61s the attempts from +0s left the window, so one more was allowed."

echo
echo "=== R3  Sessions: a hash per login, deleted automatically after 15 idle minutes ==="
r HSET session:9f2c1e customer_id 4 wallet_number 1100000001 device iphone-15 kyc_tier 1 > /dev/null
r EXPIRE session:9f2c1e 900 > /dev/null
r HGETALL session:9f2c1e
echo "TTL: $(r TTL session:9f2c1e) seconds. Each request would reset it with EXPIRE."

echo
echo "=== R4  Cache-aside for wallet balances, and why the cache must be invalidated ==="
w=1100000001
echo "1. App asks Redis first: GET bal:$w -> '$(r GET bal:$w)' (a miss)"
bal=$(pg "SELECT balance_kobo FROM wallet.wallets WHERE wallet_number = '$w'")
r SET bal:$w "$bal" EX 30 > /dev/null
echo "2. App reads PostgreSQL ($bal kobo) and caches it for 30 seconds."
echo "3. Next read is a hit: GET bal:$w -> $(r GET bal:$w)"
pg "SELECT status FROM wallet.transfer('$w', '1100000002', 100000, 'p4-cache-demo')" > /dev/null
echo "4. A N1,000 transfer commits in PostgreSQL. Balance there is now $(pg "SELECT balance_kobo FROM wallet.wallets WHERE wallet_number = '$w'")."
echo "5. Redis still says $(r GET bal:$w): a stale read, until the key expires."
r DEL bal:$w > /dev/null
echo "6. Fix: the code that commits a transfer also deletes the cached key. GET bal:$w -> '$(r GET bal:$w)'"
echo "   The next read misses and reloads the true balance. A balance shown on a screen can be"
echo "   briefly stale; the check before spending must always read PostgreSQL (Portfolio 3)."

echo
echo "=== R5  Recent activity feed: a capped list per wallet ==="
for i in 1 2 3 4 5 6 7; do
  r LPUSH feed:$w "notification $i" > /dev/null
  r LTRIM feed:$w 0 4 > /dev/null   # keep only the newest 5
done
r LRANGE feed:$w 0 -1

echo
echo "=== Memory used by these keys ==="
for k in idem:4:pay-7f3a pin:sliding:4 session:9f2c1e feed:$w; do
  echo "  $k: $(r MEMORY USAGE $k) bytes"
done

echo
echo "=== R6  Raw speed on this machine: redis-benchmark, 100,000 requests, 50 clients ==="
compose exec -T redis redis-benchmark -q -n 100000 -c 50 -t set,get,incr,lpush 2>&1 | tr '\r' '\n' | grep -v '^$' | grep 'requests per second'
