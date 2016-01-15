BEGIN;

CREATE OR REPLACE FUNCTION notify_transaction_trigger() RETURNS trigger AS $$
DECLARE
  short_code VARCHAR(255) :='';
  currency_code VARCHAR(3) :='';
  payment_remark VARCHAR(255) :='';
BEGIN
    IF NEW.action_type = 'buy'::VARCHAR OR NEW.action_type = 'sell'::VARCHAR THEN
        SELECT s.currency_code, s.short_code INTO currency_code,short_code FROM session_bet_details s WHERE fmb_id = NEW.financial_market_bet_id AND action_type = NEW.action_type;
    ELSE
        --
    END IF;
    PERFORM pg_notify('transaction_watchers', NEW.id || ',' || NEW.account_id || ',' || NEW.action_type || ',' || NEW.referrer_type || ',' || COALESCE(NEW.financial_market_bet_id,0) || ',' || COALESCE(NEW.payment_id,0) || ',' || NEW.amount || ',' || NEW.balance_after || ',' || NEW.transaction_time  || ',' || short_code || ',' || currency_code || ',' || payment_remark);
  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER watched_transaction_trigger AFTER UPDATE OR INSERT ON transaction.transaction FOR EACH ROW EXECUTE PROCEDURE notify_transaction_trigger();

COMMIT;
