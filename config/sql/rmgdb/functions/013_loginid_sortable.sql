BEGIN;
SET search_path = betonmarkets, pg_catalog;

CREATE OR REPLACE FUNCTION loginid_sortable(text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
    SELECT arr[1] || lpad(arr[2], 20, '0')
      FROM (SELECT regexp_matches($1, '(\D+)(\d+)') arr) a;
$_$;

COMMIT;
