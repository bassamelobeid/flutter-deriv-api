BEGIN;

ALTER TABLE transaction.transaction ADD COLUMN markup NUMERIC(1,2) DEFAULT 0.00;

COMMIT;
