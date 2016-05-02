BEGIN;

CREATE OR REPLACE FUNCTION update_daily_aggregates() RETURNS trigger AS $$
BEGIN
  LOOP
    UPDATE bet.daily_aggregates
      SET
        turnover = turnover - CASE WHEN TG_OP = 'UPDATE' THEN coalesce(OLD.buy_price, 0) ELSE 0 END + NEW.buy_price,         -- remove old add new
        loss = loss 
                - CASE WHEN TG_OP = 'UPDATE' THEN (coalesce(OLD.buy_price, 0) - coalesce(OLD.sell_price, 0)) ELSE 0 END    -- remove old loss
                + (NEW.buy_price - coalesce(NEW.sell_price, 0))                                                            -- add new loss
      WHERE
        day = NEW.purchase_time::date
        AND account_id = NEW.account_id;

    IF FOUND THEN
      RETURN new;
    END IF;
    
    BEGIN
      INSERT INTO bet.daily_aggregates VALUES (NEW.purchase_time::date, NEW.account_id, NEW.buy_price, NEW.buy_price - coalesce(NEW.sell_price, 0));
      RETURN new;
    EXCEPTION WHEN unique_violation THEN
      -- nothing
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
