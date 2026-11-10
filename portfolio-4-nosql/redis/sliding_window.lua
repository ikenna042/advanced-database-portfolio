-- Sliding-window rate limiter. Allows at most ARGV[3] attempts in any ARGV[2]
-- milliseconds. Redis runs the whole script atomically, so two requests arriving
-- together can't both see "4 attempts so far" and both be allowed as the 5th.
-- KEYS[1] = sorted set of attempt times for one customer
-- ARGV[1] = now (ms), ARGV[2] = window (ms), ARGV[3] = limit, ARGV[4] = unique attempt id
local key, now, window, limit = KEYS[1], tonumber(ARGV[1]), tonumber(ARGV[2]), tonumber(ARGV[3])
redis.call('ZREMRANGEBYSCORE', key, 0, now - window)   -- forget attempts older than the window
local used = redis.call('ZCARD', key)
if used >= limit then
  return {0, used}                                      -- blocked
end
redis.call('ZADD', key, now, ARGV[4])
redis.call('PEXPIRE', key, window)                      -- the key disappears when idle
return {1, used + 1}                                    -- allowed
