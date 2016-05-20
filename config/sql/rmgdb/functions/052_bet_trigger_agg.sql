BEGIN;

CREATE OR REPLACE FUNCTION bet.update_daily_aggregates_ins() RETURNS trigger AS $$
BEGIN
  LOOP
    BEGIN
      INSERT INTO bet.daily_aggregates VALUES (NEW.purchase_time::date, NEW.account_id, NEW.buy_price, NEW.buy_price - coalesce(NEW.sell_price, 0));
      RETURN new;
    EXCEPTION WHEN unique_violation THEN
      -- nothing
    END;

    UPDATE bet.daily_aggregates
      SET
        turnover = turnover + coalesce(NEW.buy_price, 0),
        loss = loss + (NEW.buy_price - coalesce(NEW.sell_price, 0))
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

CREATE OR REPLACE FUNCTION bet.update_daily_aggregates_del() RETURNS trigger AS $$
BEGIN
  LOOP
    BEGIN
      INSERT INTO bet.daily_aggregates VALUES (OLD.purchase_time::date, OLD.account_id, OLD.buy_price, OLD.buy_price - coalesce(OLD.sell_price, 0));
      RETURN old;
    EXCEPTION WHEN unique_violation THEN
      -- nothing
    END;

    UPDATE bet.daily_aggregates
      SET
        turnover = turnover - coalesce(OLD.buy_price, 0),
        loss = loss - (OLD.buy_price - coalesce(OLD.sell_price, 0))
      WHERE
          day = OLD.purchase_time::date
          AND account_id = OLD.account_id
      ;

    IF FOUND THEN
      RETURN old;
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
