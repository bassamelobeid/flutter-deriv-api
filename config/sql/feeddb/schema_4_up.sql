-- Function to monitor how big is the gap between master and slave in binary replication.
-- In PostgreSQL 9.1 all slaves can be monitored from master.
-- The gap measurement is in size.
-- This function does not need to be in feed db.
-- Fuction can be exectued in master
-- Example: select pg_size_pretty(get_feed_replication_lag_in_size('190.241.168.44'));

CREATE OR REPLACE FUNCTION hex_to_int(hexval varchar) RETURNS BIGINT AS $$
DECLARE
    result  BIGINT;
BEGIN
    EXECUTE 'SELECT x''' || hexval || '''::BIGINT' INTO result;
    RETURN result;
END;
$$ LANGUAGE 'plpgsql' IMMUTABLE STRICT;


CREATE OR REPLACE FUNCTION get_feed_replication_lag_in_byte(client_ip_addr TEXT)
RETURNS BIGINT AS $$
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
$$
LANGUAGE plpgsql
-- It should be defined by an admin user or function wont have enough permission to report correctly
SECURITY DEFINER
;
