BEGIN;

ALTER TABLE transaction.transaction ADD COLUMN markup NUMERIC;
GRANT INSERT (markup) ON TABLE transaction.transaction TO read, write;

COMMIT;
