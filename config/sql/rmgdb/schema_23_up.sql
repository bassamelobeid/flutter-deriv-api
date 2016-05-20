BEGIN;

CREATE TABLE bet.daily_aggregates (
  day        TIMESTAMP,
  account_id BIGINT REFERENCES transaction.account(id),
  turnover   NUMERIC,
  loss       NUMERIC,

  PRIMARY KEY (day, account_id)
);

GRANT  SELECT ON bet.daily_aggregates to read;
GRANT  SELECT, UPDATE, INSERT, DELETE ON bet.daily_aggregates to write;

CREATE OR REPLACE FUNCTION update_daily_aggregates() RETURNS trigger AS $$
BEGIN
  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER watched_fmbo_trigger AFTER INSERT OR DELETE ON bet.financial_market_bet_open FOR EACH ROW EXECUTE PROCEDURE update_daily_aggregates();
CREATE TRIGGER watched_fmb_trigger AFTER INSERT OR DELETE ON bet.financial_market_bet FOR EACH ROW EXECUTE PROCEDURE update_daily_aggregates();

COMMIT;
