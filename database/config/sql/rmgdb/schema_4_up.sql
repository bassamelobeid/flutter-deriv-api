BEGIN;

-- on my outdated CR copy, these 2 ALTER COLUMNs together take ~1sec. I think
-- that's acceptable.

ALTER TABLE audit.self_exclusion ADD COLUMN max_losses NUMERIC;
ALTER TABLE audit.self_exclusion ADD COLUMN max_7day_turnover NUMERIC;
ALTER TABLE audit.self_exclusion ADD COLUMN max_7day_losses NUMERIC;
ALTER TABLE audit.self_exclusion ALTER COLUMN max_turnover TYPE NUMERIC;
ALTER TABLE audit.self_exclusion ALTER COLUMN max_balance TYPE NUMERIC;

ALTER TABLE betonmarkets.self_exclusion ADD COLUMN max_losses NUMERIC;
ALTER TABLE betonmarkets.self_exclusion ADD COLUMN max_7day_turnover NUMERIC;
ALTER TABLE betonmarkets.self_exclusion ADD COLUMN max_7day_losses NUMERIC;
ALTER TABLE betonmarkets.self_exclusion ALTER COLUMN max_turnover TYPE NUMERIC;
ALTER TABLE betonmarkets.self_exclusion ALTER COLUMN max_balance TYPE NUMERIC;

COMMIT;
