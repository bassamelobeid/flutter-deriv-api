BEGIN;

ALTER TABLE betonmarkets.client ADD COLUMN allow_omnibus BOOLEAN;
ALTER TABLE audit.client ADD COLUMN allow_omnibus BOOLEAN;

ALTER TABLE betonmarkets.client ADD COLUMN sub_account_of VARCHAR(12);
ALTER TABLE betonmarkets.client ADD CONSTRAINT fk_sub_account_loginid FOREIGN KEY (sub_account_of) REFERENCES betonmarkets.client(loginid) ON UPDATE RESTRICT ON DELETE RESTRICT;

COMMIT;
