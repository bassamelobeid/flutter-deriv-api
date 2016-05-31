BEGIN;

ALTER TABLE transaction.transaction ADD COLUMN markup INT DEFAULT 0;

COMMIT;
