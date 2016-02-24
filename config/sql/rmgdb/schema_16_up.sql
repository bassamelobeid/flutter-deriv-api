BEGIN;

CREATE OR REPLACE FUNCTION session_payment_details() RETURNS trigger AS $$
BEGIN
    CREATE TEMPORARY TABLE IF NOT EXISTS session_payment_details (
        payment_id bigint,
        remark TEXT
    ) ON COMMIT DROP;
    INSERT INTO session_payment_details VALUES (NEW.id,NEW.remark);
    RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER session_payment_details AFTER UPDATE OR INSERT ON payment.payment FOR EACH ROW EXECUTE PROCEDURE session_payment_details();

COMMIT;
