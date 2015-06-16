BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION get_broker(text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
    SELECT arr[1] FROM (SELECT regexp_matches($1, '(\D+)\d+') arr) a;
$_$;

COMMIT;
