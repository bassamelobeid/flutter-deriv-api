BEGIN;

ALTER TABLE transaction.transaction ADD COLUMN markup NUMERIC DEFAULT 0;
GRANT INSERT (markup) ON TABLE transaction.transaction TO read, write;

COMMIT;
