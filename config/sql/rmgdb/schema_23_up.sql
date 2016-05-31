BEGIN;

ALTER TABLE transaction.transaction ADD COLUMN markup NUMERIC(3,2) DEFAULT 0.00;

COMMIT;
