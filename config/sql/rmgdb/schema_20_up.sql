BEGIN;

CREATE TYPE bet.session_bet_details AS (
        action_type  VARCHAR(10),
        fmb_id bigint,
        currency_code VARCHAR(3),
        short_code VARCHAR(255),
        purchase_time TIMESTAMP,
        purchase_price NUMERIC,
        sell_time TIMESTAMP,
        remark text
    );
COMMIT;
