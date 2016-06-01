BEGIN;

ALTER TABLE transaction.transaction ADD COLUMN markup NUMERIC DEFAULT 0;

COMMIT;
