BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI100', '% is not a known loginid or % is not the default currency for this account'),
           ('BI101', 'attempt to payment-agent-transfer to the same account')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;


CREATE OR REPLACE FUNCTION payment.lock_account(
        p_loginid           VARCHAR(12),
        p_currency          VARCHAR(3),
    OUT v_account           transaction.account)
RETURNS transaction.account AS $def$
BEGIN
    SELECT * INTO v_account
      FROM transaction.account a
     WHERE a.client_loginid = p_loginid
       AND a.currency_code = p_currency
       AND a.is_default
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            MESSAGE=format((SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI100'),
                           p_loginid, p_currency),
            ERRCODE='BI100';
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;



CREATE OR REPLACE FUNCTION payment.is_payment_agent(
        p_loginid           VARCHAR(12))
RETURNS BOOLEAN AS $def$
BEGIN
    PERFORM 1
       FROM betonmarkets.payment_agent a
      WHERE a.client_loginid = p_loginid;
    RETURN FOUND;    
END
$def$ LANGUAGE plpgsql STABLE;



CREATE OR REPLACE FUNCTION payment.payment_account_transfer(
        p_from_loginid      VARCHAR(12),
        p_to_loginid        VARCHAR(12),
        p_currency          VARCHAR(3),
        p_amount            NUMERIC(3),
        p_from_staff        VARCHAR(12),
        p_to_staff          VARCHAR(12),
        p_from_remark       VARCHAR(800),
        p_to_remark         VARCHAR(800),
        p_limits            JSON,
    OUT v_from_payment      payment.payment,
    OUT v_to_payment        payment.payment,
    OUT v_from_trans        transaction.transaction,
    OUT v_to_trans          transaction.transaction)
RETURNS SETOF RECORD AS $def$
DECLARE
    v_r                RECORD;
    v_from_account     transaction.account;
    v_to_account       transaction.account;
    v_gateway_code     TEXT := 'account_transfer';
BEGIN
    -- We need to lock 2 accounts. To prevent deadlocks lets lock the one with the
    -- smaller loginid first.
    v_r := payment.lock_account(LEAST(p_from_loginid, p_to_loginid), p_currency);
    IF v_r.client_loginid = p_from_loginid THEN
        v_from_account = v_r;
    ELSE
        v_to_account = v_r;
    END IF;

    v_r := payment.lock_account(GREATEST(p_from_loginid, p_to_loginid), p_currency);
    IF v_r.client_loginid = p_from_loginid THEN
        v_from_account = v_r;
    ELSE
        v_to_account = v_r;
    END IF;

    IF payment.is_payment_agent(p_from_loginid) OR payment.is_payment_agent(p_to_loginid) THEN
        v_gateway_code := 'payment_agent_transfer';
    END IF;

    INSERT INTO payment.payment (account_id, amount, payment_gateway_code,
                                 payment_type_code, status, staff_loginid, remark)
    VALUES (v_from_account.id, -p_amount, v_gateway_code,
            'internal_transfer', 'OK', p_from_staff, p_from_remark)
    RETURNING * INTO v_from_payment;

    INSERT INTO payment.payment (account_id, amount, payment_gateway_code,
                                 payment_type_code, status, staff_loginid, remark)
    VALUES (v_to_account.id, p_amount, v_gateway_code,
            'internal_transfer', 'OK', p_to_staff, p_to_remark)
    RETURNING * INTO v_to_payment;

    CASE v_gateway_code
        WHEN 'payment_agent_transfer' THEN
            INSERT INTO payment.payment_agent_transfer (payment_id, corresponding_payment_id)
            VALUES (v_from_payment.id, v_to_payment.id), (v_to_payment.id, v_from_payment.id);
        WHEN 'account_transfer' THEN
            INSERT INTO payment.account_transfer (payment_id, corresponding_payment_id)
            VALUES (v_from_payment.id, v_to_payment.id), (v_to_payment.id, v_from_payment.id);
        ELSE
            RAISE EXCEPTION 'Invalid payment gateway code %', v_gateway_code;
    END CASE;

    INSERT INTO transaction.transaction (payment_id, account_id, amount, staff_loginid,
                                         referrer_type, action_type, quantity)
    VALUES (v_from_payment.id, v_from_account.id, -p_amount, p_from_staff,
            'payment', 'withdrawal', 1)
    RETURNING * INTO v_from_trans;

    INSERT INTO transaction.transaction (payment_id, account_id, amount, staff_loginid,
                                         referrer_type, action_type, quantity)
    VALUES (v_to_payment.id, v_to_account.id, p_amount, p_to_staff,
            'payment', 'deposit', 1)
    RETURNING * INTO v_to_trans;

    RETURN NEXT;
END
$def$ LANGUAGE plpgsql VOLATILE SECURITY definer SET log_min_messages = LOG;

COMMIT;
