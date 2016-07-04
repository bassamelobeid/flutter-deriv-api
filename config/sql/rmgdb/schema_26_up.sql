BEGIN;

ALTER TABLE betonmarkets.client ADD COLUMN allow_omnibus BOOLEAN;
ALTER TABLE audit.client ADD COLUMN allow_omnibus BOOLEAN;

COMMIT;
