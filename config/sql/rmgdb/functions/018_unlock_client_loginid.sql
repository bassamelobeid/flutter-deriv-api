BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION unlock_client_loginid(f_loginid character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE betonmarkets.client_lock SET locked=false, description=''
    WHERE client_loginid=f_loginid AND locked;
    RETURN FOUND;
END;
$$;

COMMIT;
