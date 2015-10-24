BEGIN;

ALTER TABLE betonmarkets.self_exclusion ADD COLUMN max_30day_turnover NUMERIC;
ALTER TABLE betonmarkets.self_exclusion ADD COLUMN max_30day_losses   NUMERIC;

ALTER TABLE audit.self_exclusion ADD COLUMN max_30day_turnover NUMERIC;
ALTER TABLE audit.self_exclusion ADD COLUMN max_30day_losses   NUMERIC;

COMMIT;
