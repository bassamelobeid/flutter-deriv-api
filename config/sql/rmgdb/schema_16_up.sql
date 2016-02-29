BEGIN;

CREATE OR REPLACE FUNCTION session_payment_details() RETURNS trigger AS $$
BEGIN
    RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER session_payment_details AFTER UPDATE OR INSERT ON payment.payment FOR EACH ROW EXECUTE PROCEDURE session_payment_details();

COMMIT;
