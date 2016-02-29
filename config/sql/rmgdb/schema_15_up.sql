BEGIN;

CREATE OR REPLACE FUNCTION notify_transaction_trigger() RETURNS trigger AS $$
BEGIN
  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER watched_transaction_trigger AFTER UPDATE OR INSERT ON transaction.transaction FOR EACH ROW EXECUTE PROCEDURE notify_transaction_trigger();

COMMIT;

