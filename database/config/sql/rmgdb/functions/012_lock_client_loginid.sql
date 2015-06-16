BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION lock_client_loginid(f_loginid character varying, f_description text DEFAULT ''::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE c CURSOR FOR SELECT * FROM betonmarkets.client_lock WHERE client_loginid=f_loginid FOR NO KEY UPDATE NOWAIT;
DECLARE c_row Record;
BEGIN
    OPEN c;
    FETCH c INTO c_row;

    -- Check if line exists, otherwise insert one.
    IF NOT FOUND THEN
        -- we use an explicit lock here because we want to NOWAIT. This is not
        -- possible with a simple INSERT.
        -- SHARE UPDATE EXCLUSIVE is the weakest mode that conflicts with itself.
        LOCK TABLE betonmarkets.client_lock IN SHARE UPDATE EXCLUSIVE MODE NOWAIT;
        INSERT INTO betonmarkets.client_lock (client_loginid,locked,description) VALUES (f_loginid, true, f_description);
        BEGIN CLOSE c; EXCEPTION WHEN OTHERS THEN END;
        RETURN true;
    END IF;

    -- Check if client is already locked. this lock is the application lock, displayable in back-office and investigatable.
    -- This is not the same as a postgres advisory lock or SELECT FOR UPDATE.
    IF NOT c_row.locked THEN
        UPDATE betonmarkets.client_lock SET locked=true, description=f_description, time=NOW() WHERE CURRENT OF c;
        BEGIN CLOSE c; EXCEPTION WHEN OTHERS THEN END;
        RETURN true;
    END IF;

    -- If client is already locked in client_lock table.
    BEGIN CLOSE c; EXCEPTION WHEN OTHERS THEN END;
    RETURN false;

    -- another transaction is in the middle of a lock/unlock operation
    EXCEPTION
        -- we don't need to catch unique_violation because of the LOCK TABLE
        -- in front of the INSERT
        WHEN lock_not_available THEN
            BEGIN CLOSE c; EXCEPTION WHEN OTHERS THEN END;
            RETURN false;
END;
$$;

COMMIT;
