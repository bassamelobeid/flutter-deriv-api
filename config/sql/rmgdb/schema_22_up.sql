BEGIN;

CREATE TYPE aml_risk_type AS ENUM ('low', 'standard', 'high', 'manual override - low', 'manual override - standard', 'manual override - high');

ALTER TABLE betonmarkets.client
    ADD COLUMN aml_risk_classification aml_risk_type DEFAULT 'low';

ALTER TABLE audit.client
    ADD COLUMN aml_risk_classification aml_risk_type DEFAULT 'low';

COMMIT;
