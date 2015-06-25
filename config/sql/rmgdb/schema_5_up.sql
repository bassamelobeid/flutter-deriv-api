BEGIN;

SET search_path = betonmarkets, pg_catalog;

CREATE TABLE betonmarkets.financial_assessment (
    client_loginid character varying(12) NOT NULL PRIMARY KEY,
    data JSON,
    is_professional BOOLEAN
);

ALTER TABLE betonmarkets.financial_assessment
    ADD CONSTRAINT fk_financial_client_loginid FOREIGN KEY (client_loginid) REFERENCES betonmarkets.client(loginid) ON UPDATE RESTRICT ON DELETE RESTRICT;

SET search_path = audit, pg_catalog;

CREATE TABLE audit.financial_assessment (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    client_loginid character varying(12),
    data JSON,
    is_professional BOOLEAN
);

CREATE TRIGGER check_table_changes_before_change_and_backup_in_audit BEFORE INSERT OR DELETE OR UPDATE ON betonmarkets.financial_assessment FOR EACH ROW EXECUTE PROCEDURE audit.check_table_changes_before_change_and_backup_in_audit();

SET search_path = sequences, pg_catalog;

CREATE SEQUENCE loginid_sequence_mf
    START WITH 90000000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

GRANT SELECT, UPDATE, INSERT, DELETE ON betonmarkets.financial_assessment TO read, write;
GRANT ALL ON SEQUENCE sequences.loginid_sequence_mf to write;

COMMIT;
