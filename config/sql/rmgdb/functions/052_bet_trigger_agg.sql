BEGIN;

CREATE OR REPLACE FUNCTION bet.update_daily_aggregates_buy() RETURNS trigger AS $$
BEGIN
  LOOP
    BEGIN
      INSERT INTO bet.daily_aggregates VALUES (NEW.purchase_time::date, NEW.account_id, NEW.buy_price, 0);
      RETURN new;
    EXCEPTION WHEN unique_violation THEN
      -- nothing
    END;

    UPDATE bet.daily_aggregates
      SET
        turnover = turnover + NEW.buy_price
      WHERE
          day = NEW.purchase_time::date
          AND account_id = NEW.account_id
      ;

    IF FOUND THEN
      RETURN new;
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION bet.update_daily_aggregates_sell() RETURNS trigger AS $$
BEGIN
  UPDATE bet.daily_aggregates
    SET
      loss = loss + (NEW.buy_price - NEW.sell_price)
    WHERE
        day = NEW.purchase_time::date
        AND account_id = NEW.account_id
    ;

  IF FOUND THEN
    RETURN new;
  ELSE
    RETURN NULL;
  END IF;
END;
$$ LANGUAGE plpgsql;

COMMIT;
