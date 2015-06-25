-- This file is based on template. Dont remove this line!
-- This is a sample template to explain the strucutre of the database migrations files to be used in database migratiion script.
-- Everytime make a copy of this. Keep the first line. The line that contains, "-- This file is based on template.".
-- Add your changes by respecting the template structure.


BEGIN;

--CREATE A NEW TABLE

-- refer to note one Note 1, and the replicator document page. After adding a new table it must be added to the slaves. 

CREATE TABLE betonmarkets.SAMPLE (
    id int, 
    item text, 
    time timestamp
);


CREATE INDEX XYZ on betonmarkets.SAMPLE (time);


-- This is for tables that need to be under auditing system.
-- It will backup all the chagnes on tables
-- No more than one row can change per transaction for that table (DELETE, UPDATE).
-- To add the table to audit the archive table in audit must have the same name and few extra fields. Check the below temple.
CREATE TABLE audit.SAMPLE (
    operation VARCHAR(10) NOT NULL,
    stamp timestamp NOT NULL,
    pg_userid text NOT NULL,
    client_addr CIDR,
    client_port INTEGER,

    id int, 
    item text, 
    time timestamp
);

CREATE TRIGGER check_table_changes_before_change_and_backup_in_audit BEFORE INSERT OR UPDATE OR DELETE ON betonmarkets.SAMPLE FOR EACH ROW EXECUTE PROCEDURE audit.check_table_changes_before_change_and_backup_in_audit();
ALTER TABLE  betonmarkets.SAMPLE ENABLE ALWAYS TRIGGER check_table_changes_before_change_and_backup_in_audit ;


GRANT SELECT ON TABLE betonmarkets.SAMPLE TO select_on_betonmarkets;
GRANT UPDATE ON TABLE betonmarkets.SAMPLE TO update_on_betonmarkets;
GRANT INSERT ON TABLE betonmarkets.SAMPLE TO insert_on_betonmarkets;
GRANT DELETE ON TABLE betonmarkets.SAMPLE TO delete_on_betonmarkets;
-- Add this line if normal write users need to be able to delete from this table. 
-- Write role just have limited delete permission.
-- Not all tables need to be in this list.
GRANT DELETE ON TABLE betonmarkets.SAMPLE TO delete_on_betonmarkets_limited;


COMMIT;


