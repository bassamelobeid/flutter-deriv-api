BEGIN;

SET search_path TO audit;



DROP FUNCTION IF EXISTS set_staff(p_staff TEXT, p_ip_addr CIDR);
CREATE OR REPLACE FUNCTION set_staff(p_staff TEXT, p_ip_addr CIDR, p_row_count INT DEFAULT 0)
RETURNS VOID
AS $def$

BEGIN
    PERFORM 1
       FROM pg_catalog.pg_class c
      WHERE c.relname='audit_detail'
        AND c.relnamespace=pg_catalog.pg_my_temp_schema();
    IF NOT FOUND THEN
        CREATE TEMPORARY TABLE audit_detail (
            staff text not null,
            ip_addr cidr,
            row_count int
        );
    END IF;
    DELETE FROM audit_detail;
    INSERT INTO audit_detail VALUES (p_staff, p_ip_addr, p_row_count);
END;

$def$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION audit_client_tables() RETURNS TRIGGER
AS $def$

DECLARE
    image      RECORD;
    my_staff   TEXT;
    my_ip_addr CIDR;
    cols       TEXT;
    
BEGIN
    -- 'strict' enforces exactly one staff-name has been declared.
    -- Any other case (no row, no temp table, multiple rows..) is rejected.
    BEGIN
        UPDATE audit_detail SET row_count = row_count + 1
               RETURNING staff, ip_addr INTO STRICT my_staff, my_ip_addr;

    EXCEPTION
        WHEN OTHERS THEN
            -- enable next line to make explicit auditing at application level mandatory.
            -- raise exception 'must call audit.set_staff function first';
            my_staff := '?';
            my_ip_addr := NULL;
            PERFORM audit.set_staff(my_staff, my_ip_addr, 1);
    END;

    IF TG_OP = 'DELETE' THEN
        image := OLD;
    ELSE
        image := NEW;
    END IF;

    -- go dynamic here because target table name varies
    SELECT INTO cols
           string_agg(quote_ident(x), ', ')
      FROM (SELECT attname
              FROM pg_attribute
             WHERE attrelid=TG_RELID
               AND attnum>0
               AND NOT attisdropped
             ORDER BY attnum ASC) t(x);

    EXECUTE
        format('
            INSERT into audit.%I (operation, stamp, pg_userid, client_addr, client_port, remote_addr, %s)
            SELECT $1, $2, $3, $4, $5, $6, $7.*
        ', TG_TABLE_NAME, cols)
        USING TG_OP, now(), my_staff, inet_client_addr(), inet_client_port(), my_ip_addr, image;
    
    RETURN NULL;
END;

$def$ LANGUAGE plpgsql;

COMMIT;
