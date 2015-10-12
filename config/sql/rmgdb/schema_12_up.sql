BEGIN;

ALTER TABLE betonmarkets.client ADD COLUMN occupation VARCHAR(100);
ALTER TABLE audit.client ADD COLUMN occupation VARCHAR(100);

COMMIT;
