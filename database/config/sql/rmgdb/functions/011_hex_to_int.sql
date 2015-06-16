BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION hex_to_int(hexval character varying) RETURNS bigint
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $$
DECLARE
    result  BIGINT;
BEGIN
    EXECUTE 'SELECT x''' || hexval || '''::BIGINT' INTO result;
    RETURN result;
END;
$$;

COMMIT;
