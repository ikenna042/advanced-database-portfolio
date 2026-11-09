-- Uses pg_stat_statements to see the benchmark queries as the server recorded them.
-- run.sh resets the statistics, runs every query three times, then runs this report.
SET search_path = wallet, public;
\pset pager off
SELECT calls,
       round(total_exec_time::NUMERIC, 1) AS total_ms,
       round(mean_exec_time::NUMERIC, 2)  AS mean_ms,
       rows,
       shared_blks_hit,
       shared_blks_read,
       left(regexp_replace(query, '\s+', ' ', 'g'), 70) AS query
  FROM pg_stat_statements
 WHERE query ILIKE '%wallet.%' AND query NOT ILIKE '%pg_stat_statements%'
 ORDER BY total_exec_time DESC
 LIMIT 12;
