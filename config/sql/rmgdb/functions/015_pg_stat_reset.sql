BEGIN;
SET search_path = betonmarkets, pg_catalog;

CREATE OR REPLACE FUNCTION pg_stat_reset() RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    
    EXECUTE 'SELECT pg_stat_reset(); '; 
    RETURN 1;
END;
$$;

COMMIT;
