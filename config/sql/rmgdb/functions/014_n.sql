BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION n(p text) RETURNS text
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (p IS NULL) THEN
        RETURN '';
    else
        RETURN p;
    END IF;
END;
$$;

COMMIT;
