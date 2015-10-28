BEGIN;

CREATE OR REPLACE FUNCTION notify_transaction_trigger() RETURNS trigger AS $$
DECLARE
BEGIN
  PERFORM pg_notify('transaction_watchers', NEW.id || ',' || NEW.account_id || ',' || NEW.action_type || ',' || NEW.referrer_type || ',' || COALESCE(NEW.financial_market_bet_id,0) || ',' || COALESCE(NEW.payment_id,0) || ',' || NEW.amount || ',' || NEW.balance_after );
  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER watched_transaction_trigger AFTER UPDATE OR INSERT ON transaction.transaction FOR EACH ROW EXECUTE PROCEDURE notify_transaction_trigger();

COMMIT;