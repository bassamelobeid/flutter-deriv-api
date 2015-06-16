BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION get_consecutive_deposit_limit_reached(account_id integer) RETURNS boolean
    LANGUAGE plpgsql
    AS $_$
DECLARE
	counter integer := 0;
	consecutive_found boolean := FALSE;
	row_record RECORD;

BEGIN
	FOR row_record IN
		SELECT t.transaction_time, t.action_type, t.amount, p.payment_gateway_code
			FROM transaction.transaction t
				JOIN transaction.account a
					ON a.id = t.account_id
				LEFT JOIN payment.payment p
					ON t.payment_id = p.id
			WHERE a.id = $1
			ORDER BY t.transaction_time
	LOOP
		IF row_record.action_type = 'deposit'
		THEN
			IF row_record.amount >= 25 AND row_record.payment_gateway_code <> 'affiliate_reward'
			THEN
				counter := counter + 1;
				IF counter >= 4 THEN
					consecutive_found = TRUE;
					EXIT;
				END IF;
			END IF;
		ELSE
			counter := 0;
		END IF;
	END LOOP;

	RETURN consecutive_found;
END;
$_$;

COMMIT;
