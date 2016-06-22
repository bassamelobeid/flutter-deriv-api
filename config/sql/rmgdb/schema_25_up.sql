BEGIN;

ALTER TABLE transaction.transaction ADD COLUMN app_markup NUMERIC;
GRANT INSERT (app_markup) ON TABLE transaction.transaction TO read, write;

COMMIT;
