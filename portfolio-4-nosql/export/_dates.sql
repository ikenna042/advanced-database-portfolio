-- Prepended to each export. MongoDB Extended JSON: {"$date": "..."} is imported as a
-- real BSON date, not a string.
SET search_path = wallet, public;
CREATE FUNCTION pg_temp.d(ts TIMESTAMPTZ) RETURNS JSON
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN ts IS NULL THEN NULL
                ELSE json_build_object('$date', to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))
           END
$$;
