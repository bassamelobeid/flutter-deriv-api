BEGIN;

CREATE OR REPLACE FUNCTION betonmarkets.production_servers(include_VR BOOLEAN DEFAULT false,
                                                           include_DC BOOLEAN DEFAULT false)
RETURNS TABLE(srvname TEXT) AS $def$

  SELECT s.srvname::TEXT
    FROM pg_catalog.pg_foreign_data_wrapper w
    JOIN pg_catalog.pg_foreign_server s ON (s.srvfdw=w.oid)
   WHERE w.fdwname IN ('postgres_fdw', 'dblink_fdw')
     AND (include_VR OR s.srvname<>'vr')
     AND (include_DC OR s.srvname<>'dc')

$def$ LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION betonmarkets.production_servers(BOOLEAN, BOOLEAN) TO client_read, client_write, general_write;

COMMIT;
