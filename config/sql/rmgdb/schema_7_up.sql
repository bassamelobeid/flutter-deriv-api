begin;

    ------------------------------------------------------------------
    -- correct various perms missing from the migrate sequence to date

    create schema if not exists audit;
    grant select on all tables in schema audit to read;
    grant all privileges on schema audit to write;
    grant all privileges on all tables in schema audit to write;

    ------------------------------------------------------------------
    -- add new 'remote_addr' column to audit tables

    set search_path to audit;
    alter table client                         add column remote_addr cidr;
    alter table client_status                  add column remote_addr cidr;
    alter table client_promo_code              add column remote_addr cidr;
    alter table client_authentication_method   add column remote_addr cidr;
    alter table client_authentication_document add column remote_addr cidr;
    alter table payment_agent                  add column remote_addr cidr;
    alter table self_exclusion                 add column remote_addr cidr;
    alter table financial_assessment           add column remote_addr cidr;
    ------------------------------------------------------------------
    -- set_staff makes a staff name and remote ip_addr available to the audit triggers

    set search_path to audit;
    create or replace function set_staff(staff text, ip_addr cidr) returns void
    as $def$

    begin
        create temporary table if not exists audit_detail (
             staff text not null,
             ip_addr cidr,
             row_count int
         );
        delete from audit_detail;
        insert into audit_detail values (staff, ip_addr, 0);
    end;

    $def$ language plpgsql;

    ------------------------------------------------------------------
    -- audit_client_tables will save the row image plus transaction data
    -- into the corresponding audit table after any dml

    set search_path to audit;
    create or replace function audit_client_tables() returns trigger
    AS $def$

    declare
        image      record;
        my_staff   text;
        my_ip_addr cidr;
        
    begin
        -- 'strict' enforces exactly one staff-name has been declared.
        -- Any other case (no row, no temp table, multiple rows..) is rejected.
        begin
            select staff, ip_addr into strict my_staff, my_ip_addr from audit_detail;
        exception
            when others then
                -- enable next line to make explicit auditing at application level mandatory.
                -- raise exception 'must call audit.set_staff function first';
                my_staff := '?';
                my_ip_addr := NULL;
                perform audit.set_staff(my_staff, my_ip_addr);
        end;
        update audit_detail set row_count = row_count + 1;

        if (TG_OP = 'DELETE') then
            image := OLD;
        else
            image := NEW;
        end if;

        -- go dynamic here because target table name varies
        execute
            format('insert into audit.%I values($1,$2,$3,$4,$5,($6).*, $7)', TG_TABLE_NAME)
            using TG_OP, transaction_timestamp(), my_staff, inet_client_addr(), inet_client_port(), image, my_ip_addr;
        
        return NULL;
    end;

    $def$ language plpgsql;

    ------------------------------------------------------------------
    -- no_multirow_dml will prohibit multiple-row dml (well, more than 2 anyway)

    set search_path to audit;
    create or replace function audit.no_multirow_dml() returns trigger
    AS $def$

    declare
        ad record;
        
    begin
        select * into ad from audit_detail;
        if ad.row_count > 2 then
            raise exception 'Multiple-row operations on %.% prohibited. This % by % would affect % rows.',
                                TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP, ad.staff, ad.row_count;
        end if;
        delete from audit_detail;
        return NULL;
    end;

    $def$ language plpgsql;

    ------------------------------------------------------------------
    -- drop triggers accidentally declared in wrong schema

    set search_path to audit;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on client;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on client_status;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on client_promo_code;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on client_authentication_method;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on client_authentication_document;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on payment_agent;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on self_exclusion;

    ------------------------------------------------------------------
    -- drop old auditing triggers

    set search_path to betonmarkets;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on client;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on client_status;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on client_promo_code;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on client_authentication_method;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on client_authentication_document;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on payment_agent;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on self_exclusion;
    drop trigger if exists check_table_changes_before_change_and_backup_in_audit on financial_assessment;

    ------------------------------------------------------------------
    -- create new row-level triggers to do auto auditing

    set search_path to betonmarkets;

    create trigger audit_client_table after insert or update or delete on client
        for each row execute procedure audit.audit_client_tables();

    create trigger audit_client_table after insert or update or delete on client_status
        for each row execute procedure audit.audit_client_tables();

    create trigger audit_client_table after insert or update or delete on client_promo_code
        for each row execute procedure audit.audit_client_tables();

    create trigger audit_client_table after insert or update or delete on payment_agent
        for each row execute procedure audit.audit_client_tables();

    create trigger audit_client_table after insert or update or delete on client_authentication_method
        for each row execute procedure audit.audit_client_tables();

    create trigger audit_client_table after insert or update or delete on client_authentication_document
        for each row execute procedure audit.audit_client_tables();

    create trigger audit_client_table after insert or update or delete on self_exclusion
        for each row execute procedure audit.audit_client_tables();

    create trigger audit_client_table after insert or update or delete on financial_assessment
        for each row execute procedure audit.audit_client_tables();

    ------------------------------------------------------------------
    -- create new triggers to do limit multi-row dml
    -- note, these are executed once only at end of statement, not per row.

    set search_path to betonmarkets;

    create trigger no_multirow_dml after update or delete on client
        execute procedure audit.no_multirow_dml();

    create trigger no_multirow_dml after update or delete on client_status
        execute procedure audit.no_multirow_dml();

    create trigger no_multirow_dml after update or delete on client_promo_code
        execute procedure audit.no_multirow_dml();

    create trigger no_multirow_dml after update or delete on payment_agent
        execute procedure audit.no_multirow_dml();

    create trigger no_multirow_dml after update or delete on client_authentication_method
        execute procedure audit.no_multirow_dml();

    create trigger no_multirow_dml after update or delete on client_authentication_document
        execute procedure audit.no_multirow_dml();

    create trigger no_multirow_dml after update or delete on self_exclusion
        execute procedure audit.no_multirow_dml();

    create trigger no_multirow_dml after update or delete on financial_assessment
        execute procedure audit.no_multirow_dml();

    ------------------------------------------------------------------

commit;

