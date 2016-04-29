BEGIN;

CREATE OR REPLACE FUNCTION notify_transaction_trigger() RETURNS trigger AS $$
DECLARE
  details bet.session_bet_details;
BEGIN
  details := current_setting('binary.session_details')::bet.session_bet_details;

  IF details.fmb_id = NEW.financial_market_bet_id THEN
    PERFORM pg_notify('transaction_watchers'
            , NEW.id
            || ',' || NEW.account_id
            || ',' || NEW.action_type
            || ',' || NEW.referrer_type
            || ',' || COALESCE(NEW.financial_market_bet_id,0)
            || ',' || COALESCE(NEW.payment_id,0)
            || ',' || NEW.amount
            || ',' || NEW.balance_after
            || ',' || NEW.transaction_time 
            || ',' || coalesce(details.short_code::text, '')
            || ',' || coalesce(details.currency_code::text, '')
            || ',' || coalesce(details.purchase_time::text, '')
            || ',' || coalesce(details.purchase_price::text, '')
            || ',' || coalesce(details.sell_time::text, '')
            || ',' || ''
          )
        , set_config('binary.session_details', '', true);
  ELSIF details.fmb_id = NEW.payment_id THEN
    PERFORM pg_notify('transaction_watchers'
            , NEW.id
            || ',' || NEW.account_id
            || ',' || NEW.action_type
            || ',' || NEW.referrer_type
            || ',' || COALESCE(NEW.financial_market_bet_id,0)
            || ',' || COALESCE(NEW.payment_id,0)
            || ',' || NEW.amount
            || ',' || NEW.balance_after
            || ',' || NEW.transaction_time 
            || ',' || ''
            || ',' || ''
            || ',' || ''
            || ',' || ''
            || ',' || ''
            || ',' || coalesce(details.remark::text, '')
          )
        ,set_config('binary.session_details', '', true);
  END IF;

  RETURN new;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION session_payment_details() RETURNS trigger AS $$
BEGIN
    PERFORM set_config('binary.session_details', ((NULL, NEW.id, NULL, NULL, NULL, NULL, NULL, NEW.remark)::bet.session_bet_details)::text, true);
    RETURN new;
END;
$$ LANGUAGE plpgsql;

COMMIT;
