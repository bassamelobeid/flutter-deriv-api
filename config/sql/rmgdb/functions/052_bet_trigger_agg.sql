BEGIN;


CREATE OR REPLACE FUNCTION update_daily_aggregates() RETURNS trigger AS $$
BEGIN
  LOOP
    -- when delete in same period
    -- when delete in new period
  
    IF TG_OP = 'INSERT' THEN
      BEGIN
        INSERT INTO bet.daily_aggregates VALUES (NEW.purchase_time::date, NEW.account_id, NEW.buy_price, NEW.buy_price - coalesce(NEW.sell_price, 0));
        RETURN new;
      EXCEPTION WHEN unique_violation THEN
        -- nothing
      END;
    ELSIF TG_OP = 'DELETE' THEN
      BEGIN
        INSERT INTO bet.daily_aggregates VALUES (OLD.purchase_time::date, OLD.account_id, OLD.buy_price, OLD.buy_price - coalesce(OLD.sell_price, 0));
        RETURN old;
      EXCEPTION WHEN unique_violation THEN
        -- nothing
      END;
    END IF;
    
    UPDATE bet.daily_aggregates
      SET
        turnover = turnover
            + CASE WHEN TG_OP = 'INSERT' THEN coalesce(NEW.buy_price, 0) ELSE 0 END                     -- add new
            - CASE WHEN TG_OP = 'DELETE' THEN coalesce(OLD.buy_price, 0) ELSE 0 END                     -- del old
        ,loss = loss 
            + CASE WHEN TG_OP = 'INSERT' THEN (NEW.buy_price - coalesce(NEW.sell_price, 0)) ELSE 0 END  -- add new loss
            - CASE WHEN TG_OP = 'DELETE' THEN (OLD.buy_price - coalesce(OLD.sell_price, 0)) ELSE 0 END  -- del old loss
      WHERE
        day = coalesce(NEW.purchase_time::date, OLD.purchase_time::date)
        AND account_id = coalesce(NEW.account_id, OLD.account_id);

    IF FOUND THEN
      RETURN coalesce(new, old);
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
