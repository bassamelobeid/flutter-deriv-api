BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION get_client_replication_lag_by_application_name(client_application_name text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE slave_location TEXT;
DECLARE master_location TEXT;
BEGIN
    SELECT  pg_current_xlog_location() INTO master_location;
    SELECT  sent_location FROM pg_stat_replication where application_name = client_application_name INTO slave_location;

    IF slave_location IS null THEN
        RETURN -1;
    ELSE
        RETURN pg_xlog_location_diff(master_location, slave_location);
    END IF;
END;
$$;

COMMIT;
