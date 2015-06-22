BEGIN;

SET search_path = betonmarkets, pg_catalog;

ALTER TABLE betonmarkets.client DROP COLUMN IF EXISTS driving_license;
ALTER TABLE betonmarkets.client DROP COLUMN IF EXISTS fax;

SET search_path = audit, pg_catalog;

ALTER TABLE audit.client DROP COLUMN IF EXISTS driving_license;
ALTER TABLE audit.client DROP COLUMN IF EXISTS fax;

COMMIT;
