BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION get_client_replication_lag_in_byte(client_ip_addr text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE slave_location BIGINT;
DECLARE master_location BIGINT;
BEGIN
    SELECT  hex_to_int(replace(pg_current_xlog_location(),'/','')) INTO master_location;
    SELECT  hex_to_int(replace(sent_location,'/','')) FROM pg_stat_replication where host(client_addr) = client_ip_addr INTO slave_location;

    IF slave_location IS null THEN
        RETURN -1;
    ELSE
        RETURN master_location-slave_location;
    END IF;
END;
$$;

COMMIT;
