BEGIN;

CREATE TABLE IF NOT EXISTS bet.daily_aggregates (
  day        TIMESTAMP,
  account_id BIGINT REFERENCES transaction.account(id),
  turnover   NUMERIC,
  loss       NUMERIC,

  PRIMARY KEY (day, account_id)
);

GRANT  SELECT ON bet.daily_aggregates to read;
GRANT  SELECT, UPDATE, INSERT, DELETE ON bet.daily_aggregates to write;

CREATE OR REPLACE FUNCTION bet.update_daily_aggregates_buy() RETURNS trigger AS $$
BEGIN
  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION bet.update_daily_aggregates_sell() RETURNS trigger AS $$
BEGIN
  RETURN new;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS watched_fmbo_trigger_ins ON bet.financial_market_bet_open;
DROP TRIGGER IF EXISTS watched_fmb_trigger ON bet.financial_market_bet;
CREATE TRIGGER watched_fmbo_trigger_ins AFTER INSERT ON bet.financial_market_bet_open FOR EACH ROW EXECUTE PROCEDURE bet.update_daily_aggregates_buy();
CREATE TRIGGER watched_fmb_trigger AFTER INSERT OR UPDATE ON bet.financial_market_bet FOR EACH ROW EXECUTE PROCEDURE bet.update_daily_aggregates_sell();

COMMIT;
