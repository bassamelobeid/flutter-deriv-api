BEGIN;

CREATE OR REPLACE FUNCTION notify_transaction_trigger() RETURNS trigger AS $$
DECLARE
  short_code VARCHAR(255) :='';
  currency_code VARCHAR(3) :='';
  payment_remark VARCHAR(255) :='';
  purchase_time TEXT := '';
  sell_time TEXT := '';
  purchase_price NUMERIC := 0;
BEGIN
    PERFORM 1 FROM pg_class
        WHERE relname = 'session_bet_details' AND relnamespace = pg_my_temp_schema();
    IF FOUND THEN
        IF NEW.action_type = 'sell'::VARCHAR THEN
            sell_time = NEW.transaction_time::TIMESTAMP(0)::TEXT;
        END IF;
        IF NEW.action_type = 'buy'::VARCHAR OR NEW.action_type = 'sell'::VARCHAR THEN
            SELECT s.currency_code, s.short_code, s.purchase_time::TIMESTAMP(0)::TEXT, s.purchase_price INTO currency_code, short_code, purchase_time, purchase_price FROM session_bet_details s WHERE fmb_id = NEW.financial_market_bet_id AND action_type = NEW.action_type;
        END IF;
    END IF;
    PERFORM 1 FROM pg_class
        WHERE relname='session_payment_details' AND relnamespace = pg_my_temp_schema();
    IF FOUND THEN
        IF NEW.action_type = 'withdraw'::VARCHAR OR NEW.action_type = 'deposit'::VARCHAR THEN
            SELECT s.remark INTO payment_remark FROM session_payment_details s WHERE payment_id=NEW.payment_id;
        END IF;
    END IF;
    PERFORM pg_notify('transaction_watchers', NEW.id || ',' || NEW.account_id || ',' || NEW.action_type || ',' || NEW.referrer_type || ',' || COALESCE(NEW.financial_market_bet_id,0) || ',' || COALESCE(NEW.payment_id,0) || ',' || NEW.amount || ',' || NEW.balance_after || ',' || NEW.transaction_time  || ',' || short_code ||  ',' || currency_code || ',' || purchase_time || ',' || purchase_price || ',' || sell_time || ',' || payment_remark);
  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER watched_transaction_trigger AFTER UPDATE OR INSERT ON transaction.transaction FOR EACH ROW EXECUTE PROCEDURE notify_transaction_trigger();

COMMIT;
