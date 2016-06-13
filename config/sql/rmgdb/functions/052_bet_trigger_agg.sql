BEGIN;

CREATE OR REPLACE FUNCTION bet.update_daily_aggregates_buy() RETURNS trigger AS $$
BEGIN
  LOOP
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

    BEGIN
      INSERT INTO bet.daily_aggregates(day, account_id, turnover, loss)
      VALUES (NEW.purchase_time::date, NEW.account_id, NEW.buy_price, 0);
      RETURN new;
    EXCEPTION WHEN unique_violation THEN
      -- nothing
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION bet.update_daily_aggregates_sell() RETURNS trigger AS $$
BEGIN

  -- For our loss limit calculation, open contracts always count as lost. So, even a long-running contract that was bought
  -- ages ago counts as a loss as long as it's open. For sold contracts it's, hence, safe to define the time of the loss as
  -- the purchase date. This means we don't need to insert anything here. If the contract is so old that the purchase date
  -- row has already been removed, then nothing is updated and that is fine because it doesn't matter.

  UPDATE bet.daily_aggregates
    SET
      loss = loss + (NEW.buy_price - NEW.sell_price)
    WHERE
        day = NEW.purchase_time::date
        AND account_id = NEW.account_id
    ;

  RETURN new;
END;
$$ LANGUAGE plpgsql;

COMMIT;
