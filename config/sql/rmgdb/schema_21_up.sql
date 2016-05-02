BEGIN;

CREATE TABLE bet.daily_aggregates (
  day        TIMESTAMP,
  account_id BIGINT REFERENCES transaction.account(id),
  turnover   NUMERIC,
  loss       NUMERIC,

  PRIMARY KEY (day, account_id)
);

GRANT  SELECT, UPDATE, INSERT ON bet.daily_aggregates to read, write;

CREATE OR REPLACE FUNCTION update_daily_aggregates() RETURNS trigger AS $$
BEGIN
  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER watched_bet_trigger AFTER UPDATE OR INSERT ON bet.financial_market_bet FOR EACH ROW EXECUTE PROCEDURE update_daily_aggregates();

COMMIT;
