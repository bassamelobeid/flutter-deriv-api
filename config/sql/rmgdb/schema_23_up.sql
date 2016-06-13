BEGIN;

ALTER TABLE betonmarkets.self_exclusion ADD COLUMN timeout_until NUMERIC;

COMMIT;
