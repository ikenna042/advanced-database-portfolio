-- Reads the actual tables, keys and constraints back from PostgreSQL's catalog.
\pset pager off
\echo '== Tables and columns =='
SELECT table_name, ordinal_position AS pos, column_name, data_type, is_nullable AS nullable
  FROM information_schema.columns
 WHERE table_schema = 'wallet'
   AND table_name NOT LIKE 'v\_%'
 ORDER BY table_name, ordinal_position;
\echo '== Constraints =='
SELECT rel.relname AS table_name,
       CASE con.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY'
                        WHEN 'u' THEN 'UNIQUE' WHEN 'c' THEN 'CHECK' ELSE 'TRIGGER' END AS type,
       con.conname AS constraint_name,
       pg_get_constraintdef(con.oid) AS definition
  FROM pg_constraint con
  JOIN pg_class rel ON rel.oid = con.conrelid
  JOIN pg_namespace ns ON ns.oid = rel.relnamespace
 WHERE ns.nspname = 'wallet'
 ORDER BY rel.relname, type, con.conname;
\echo '== Unique expression and partial indexes =='
SELECT tablename, indexname, indexdef
  FROM pg_indexes
 WHERE schemaname = 'wallet'
   AND indexname IN ('customers_email_unique', 'staff_email_unique', 'kyc_reviews_one_live_per_tier')
 ORDER BY tablename, indexname;
\echo '== Triggers =='
SELECT event_object_table AS table_name, trigger_name, event_manipulation AS event, action_timing AS timing
  FROM information_schema.triggers
 WHERE trigger_schema = 'wallet'
 ORDER BY table_name, trigger_name, event;
