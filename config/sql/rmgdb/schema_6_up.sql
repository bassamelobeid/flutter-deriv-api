BEGIN;

ALTER TABLE transaction.transaction ADD COLUMN source BIGINT;
GRANT INSERT (source) ON TABLE transaction.transaction TO read, write;

COMMIT;
