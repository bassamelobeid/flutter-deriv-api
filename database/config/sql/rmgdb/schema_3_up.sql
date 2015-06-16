BEGIN;

SET search_path = betonmarkets, pg_catalog;

ALTER TABLE payment_agent RENAME COLUMN comission_deposit TO commission_deposit;
ALTER TABLE payment_agent RENAME COLUMN comission_withdrawal TO commission_withdrawal;

SET search_path = audit, pg_catalog;
ALTER TABLE payment_agent RENAME COLUMN comission_deposit TO commission_deposit;
ALTER TABLE payment_agent RENAME COLUMN comission_withdrawal TO commission_withdrawal;

COMMIT;
