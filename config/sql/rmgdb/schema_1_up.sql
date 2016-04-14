BEGIN;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

CREATE SCHEMA accounting;
CREATE SCHEMA audit;
CREATE SCHEMA bet;
CREATE SCHEMA betonmarkets;
CREATE SCHEMA data_collection;
CREATE SCHEMA payment;
CREATE SCHEMA sequences;
CREATE SCHEMA transaction;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION prevent_action() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
        RAISE EXCEPTION
            '% on %.% is not allowed.', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
    END;
$$;

CREATE OR REPLACE PROCEDURAL LANGUAGE plperlu;
CREATE EXTENSION IF NOT EXISTS plpgsql WITH SCHEMA pg_catalog;
COMMENT ON EXTENSION plpgsql IS 'PL/pgSQL procedural language';

CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA public;
COMMENT ON EXTENSION dblink IS 'connect to other PostgreSQL databases from within a database';

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;
COMMENT ON EXTENSION pg_stat_statements IS 'track execution statistics of all SQL statements executed';

CREATE EXTENSION IF NOT EXISTS postgres_fdw WITH SCHEMA public;
COMMENT ON EXTENSION postgres_fdw IS 'foreign-data wrapper for remote PostgreSQL servers';

SET search_path = public, pg_catalog;


CREATE SERVER dc FOREIGN DATA WRAPPER postgres_fdw OPTIONS (
    dbname 'regentmarkets',
    host 'replica-dc'
);

GRANT USAGE ON FOREIGN SERVER dc TO read;
GRANT USAGE ON FOREIGN SERVER dc TO write;

CREATE USER MAPPING FOR postgres SERVER dc OPTIONS (
    password 'mRX1E3Mi00oS8LG',
    "user" 'read'
);

CREATE USER MAPPING FOR read SERVER dc OPTIONS (
    password 'mRX1E3Mi00oS8LG',
    "user" 'read'
);

CREATE USER MAPPING FOR write SERVER dc OPTIONS (
    password 'mRX1E3Mi00oS8LG',
    "user" 'read'
);

SET search_path = sequences, pg_catalog;

CREATE SEQUENCE global_serial
    START WITH 19
    INCREMENT BY 20
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

SET search_path = audit, pg_catalog;

CREATE TABLE account (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    id bigint NOT NULL,
    client_loginid character varying(12) NOT NULL,
    currency_code character varying(3) NOT NULL,
    balance numeric(14,4) DEFAULT 0 NOT NULL,
    is_default boolean DEFAULT true NOT NULL,
    last_modified timestamp without time zone
);

CREATE TABLE account_transfer (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    payment_id bigint NOT NULL,
    corresponding_payment_id bigint
);

CREATE TABLE affiliate (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    client_loginid character varying(12) NOT NULL,
    affiliate_type character varying(100) NOT NULL,
    approved boolean DEFAULT false NOT NULL,
    company_loss_since_last_payment numeric(9,2) DEFAULT 0 NOT NULL,
    currency_code character varying(3) DEFAULT 'USD'::character varying NOT NULL,
    apply_max_earning_restriction boolean DEFAULT true NOT NULL,
    apply_date timestamp(0) without time zone DEFAULT now(),
    affiliate_name character varying(100) NOT NULL,
    phone character varying(100) NOT NULL,
    email character varying(100) NOT NULL,
    url character varying(100) NOT NULL,
    environment character varying(1024) NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    approved_date timestamp(0) without time zone DEFAULT NULL::timestamp without time zone
);

CREATE TABLE affiliate_reward (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    payment_id bigint NOT NULL,
    reward_from_date date,
    reward_to_date date
);

CREATE TABLE bank_wire (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    payment_id bigint NOT NULL,
    client_name character varying(100) DEFAULT ''::character varying NOT NULL,
    bom_bank_info character varying(150) DEFAULT ''::character varying NOT NULL,
    date_received timestamp(0) without time zone,
    bank_reference character varying(50) DEFAULT ''::character varying NOT NULL,
    bank_name character varying(50) DEFAULT ''::character varying NOT NULL,
    bank_address character varying(150) DEFAULT ''::character varying NOT NULL,
    bank_account_number character varying(50) DEFAULT ''::character varying NOT NULL,
    bank_account_name character varying(50) DEFAULT ''::character varying NOT NULL,
    iban character varying(50) DEFAULT ''::character varying NOT NULL,
    sort_code character varying(150) DEFAULT ''::character varying NOT NULL,
    swift character varying(11) DEFAULT ''::character varying NOT NULL,
    aba character varying(50) DEFAULT ''::character varying NOT NULL,
    extra_info character varying(500) DEFAULT ''::character varying NOT NULL
);

CREATE TABLE client (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    loginid character varying(12) NOT NULL,
    client_password character varying(255) NOT NULL,
    first_name character varying(50) NOT NULL,
    last_name character varying(50) NOT NULL,
    email character varying(100) NOT NULL,
    allow_login boolean DEFAULT true NOT NULL,
    broker_code character varying(32) NOT NULL,
    residence character varying(100) NOT NULL,
    citizen character varying(100) NOT NULL,
    salutation character varying(30) NOT NULL,
    address_line_1 character varying(1000) NOT NULL,
    address_line_2 character varying(255) NOT NULL,
    address_city character varying(300) NOT NULL,
    address_state character varying(100) NOT NULL,
    address_postcode character varying(64) NOT NULL,
    phone character varying(255) NOT NULL,
    date_joined timestamp(0) without time zone DEFAULT now(),
    latest_environment character varying(1024) NOT NULL,
    secret_question character varying(255) NOT NULL,
    secret_answer character varying(500) NOT NULL,
    restricted_ip_address character varying(50) NOT NULL,
    gender character varying(1) NOT NULL,
    cashier_setting_password character varying(255) NOT NULL,
    date_of_birth date,
    small_timer character varying(30) DEFAULT 'yes'::character varying NOT NULL,
    fax character varying(255) NOT NULL,
    driving_license character varying(50) NOT NULL,
    comment text DEFAULT ''::text NOT NULL,
    myaffiliates_token character varying(32) DEFAULT NULL::character varying,
    myaffiliates_token_registered boolean DEFAULT false NOT NULL,
    checked_affiliate_exposures boolean DEFAULT false NOT NULL,
    custom_max_acbal integer,
    custom_max_daily_turnover integer,
    custom_max_payout integer,
    vip_since timestamp without time zone,
    payment_agent_withdrawal_expiration_date date,
    first_time_login boolean DEFAULT true
);

CREATE TABLE client_authentication_document (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    id bigint NOT NULL,
    document_type character varying(100) NOT NULL,
    document_format character varying(100) NOT NULL,
    document_path character varying(255) NOT NULL,
    client_loginid character varying(12) NOT NULL,
    authentication_method_code character varying(50) NOT NULL,
    expiration_date date
);

CREATE TABLE client_authentication_method (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    id bigint,
    client_loginid character varying(12) NOT NULL,
    authentication_method_code character varying(50) NOT NULL,
    last_modified_date timestamp(0) without time zone,
    status character varying(100) NOT NULL,
    description text DEFAULT ''::text NOT NULL
);

CREATE TABLE client_promo_code (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    id bigint,
    client_loginid character varying(12) NOT NULL,
    promotion_code character varying(20) NOT NULL,
    apply_date timestamp(0) without time zone,
    status character varying(100) NOT NULL,
    mobile character varying(20) NOT NULL,
    checked_in_myaffiliates boolean DEFAULT false NOT NULL
);

CREATE TABLE client_status (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    id bigint,
    client_loginid character varying(12) NOT NULL,
    status_code character varying(32) NOT NULL,
    staff_name character varying(100) NOT NULL,
    reason character varying(1000) NOT NULL,
    last_modified_date timestamp(0) without time zone DEFAULT now()
);

CREATE TABLE currency_conversion_transfer (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    payment_id bigint NOT NULL,
    corresponding_payment_id bigint
);

CREATE TABLE db_activity (
    current_session_user text,
    last_activity timestamp without time zone DEFAULT '1900-01-01 00:00:00'::timestamp without time zone,
    max_allowed_inactivity interval DEFAULT '1 day'::interval
);

CREATE TABLE doughflow (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    payment_id bigint NOT NULL,
    transaction_type character varying(15) NOT NULL,
    trace_id bigint NOT NULL,
    created_by character varying(50),
    payment_processor character varying(50) NOT NULL,
    ip_address character varying(15),
    transaction_id character varying(100)
);

CREATE TABLE financial_market_bet (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    id bigint NOT NULL,
    purchase_time timestamp without time zone DEFAULT now(),
    account_id bigint NOT NULL,
    underlying_symbol character varying(50),
    payout_price numeric,
    buy_price numeric NOT NULL,
    sell_price numeric,
    start_time timestamp without time zone,
    expiry_time timestamp without time zone,
    settlement_time timestamp without time zone,
    expiry_daily boolean DEFAULT false NOT NULL,
    is_expired boolean DEFAULT false,
    is_sold boolean DEFAULT false,
    bet_class character varying(30) NOT NULL,
    bet_type character varying(30) NOT NULL,
    remark character varying(800),
    short_code character varying(255),
    sell_time timestamp without time zone,
    fixed_expiry boolean,
    tick_count integer
);

CREATE TABLE free_gift (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    payment_id bigint NOT NULL,
    promotional_code character varying(50),
    reason character varying(255)
);

CREATE TABLE higher_lower_bet (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    financial_market_bet_id bigint NOT NULL,
    relative_barrier character varying(20),
    absolute_barrier numeric,
    prediction character varying(20)
);

CREATE TABLE legacy_bet (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    financial_market_bet_id bigint NOT NULL,
    absolute_lower_barrier numeric,
    absolute_higher_barrier numeric,
    intraday_ifunless character varying(50),
    intraday_starthour character varying(10),
    intraday_leg1 character varying(10),
    intraday_midhour character varying(10),
    intraday_leg2 character varying(10),
    intraday_endhour character varying(10),
    short_code character varying(255)
);

CREATE TABLE legacy_payment (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    payment_id bigint NOT NULL,
    legacy_type character varying(255)
);

CREATE TABLE login_history (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    id bigint NOT NULL,
    client_loginid character varying(12) NOT NULL,
    login_environment character varying(1024) NOT NULL,
    login_date timestamp(0) without time zone DEFAULT now(),
    login_successful boolean NOT NULL,
    login_action character varying(255) NOT NULL
);

CREATE TABLE payment (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    id bigint NOT NULL,
    payment_time timestamp(0) without time zone DEFAULT now(),
    amount numeric(14,4) NOT NULL,
    payment_gateway_code character varying(50) NOT NULL,
    payment_type_code character varying(50) NOT NULL,
    status character varying(20) NOT NULL,
    account_id bigint NOT NULL,
    staff_loginid character varying(12) NOT NULL,
    remark character varying(800) DEFAULT ''::character varying NOT NULL
);

CREATE TABLE payment_agent (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    client_loginid character varying(12) NOT NULL,
    payment_agent_name character varying(100) NOT NULL,
    url character varying(100) NOT NULL,
    email character varying(100) NOT NULL,
    phone character varying(40) NOT NULL,
    information character varying(500) NOT NULL,
    summary character varying(255) NOT NULL,
    comission_deposit real NOT NULL,
    comission_withdrawal real NOT NULL,
    is_authenticated boolean NOT NULL,
    api_ip character varying(64),
    currency_code character varying(3) NOT NULL,
    currency_code_2 character varying(3) NOT NULL,
    target_country character varying(255) DEFAULT ''::character varying NOT NULL,
    supported_banks character varying(500)
);

CREATE TABLE payment_agent_transfer (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    payment_id bigint NOT NULL,
    corresponding_payment_id bigint
);

CREATE TABLE payment_fee (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    payment_id bigint NOT NULL,
    corresponding_payment_id bigint
);

CREATE TABLE promo_code (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    code character varying(20) NOT NULL,
    start_date timestamp(0) without time zone,
    expiry_date timestamp(0) without time zone,
    status boolean DEFAULT true NOT NULL,
    promo_code_type character varying(100) NOT NULL,
    promo_code_config text NOT NULL,
    description character varying(255) NOT NULL
);

CREATE TABLE range_bet (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    financial_market_bet_id bigint NOT NULL,
    relative_lower_barrier character varying(20),
    absolute_lower_barrier numeric,
    relative_higher_barrier character varying(20),
    absolute_higher_barrier numeric,
    prediction character varying(20)
);

CREATE TABLE run_bet (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    financial_market_bet_id bigint NOT NULL,
    number_of_ticks integer,
    last_digit integer,
    prediction character varying(20)
);

CREATE TABLE self_exclusion (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    client_loginid character varying(12) NOT NULL,
    max_balance integer,
    max_turnover integer,
    max_open_bets integer,
    exclude_until date,
    session_duration_limit integer,
    last_modified_date timestamp(0) without time zone DEFAULT now()
);

CREATE TABLE touch_bet (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    financial_market_bet_id bigint NOT NULL,
    relative_barrier character varying(20),
    absolute_barrier numeric,
    prediction character varying(20)
);

CREATE TABLE transaction (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    transaction_time timestamp without time zone DEFAULT now(),
    amount numeric(14,4) NOT NULL,
    staff_loginid character varying(24),
    remark character varying(800),
    referrer_type character varying(20) NOT NULL,
    financial_market_bet_id bigint,
    payment_id bigint,
    action_type character varying(20) NOT NULL,
    quantity integer DEFAULT 1
);

CREATE TABLE western_union (
    operation character varying(10) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    pg_userid text NOT NULL,
    client_addr cidr,
    client_port integer,
    payment_id bigint NOT NULL,
    mtcn_number character varying(15) NOT NULL,
    payment_country character varying(64) NOT NULL,
    secret_answer character varying(128)
);

SET search_path = bet, pg_catalog;

CREATE TABLE bet_dictionary (
    id bigint DEFAULT nextval('sequences.global_serial'::regclass) NOT NULL,
    bet_type character varying(30) NOT NULL,
    path_dependent boolean,
    table_name character varying(30) NOT NULL,
    CONSTRAINT bet_dictionary_table_name_check CHECK (((table_name)::text = ANY ((ARRAY['touch_bet'::character varying, 'range_bet'::character varying, 'higher_lower_bet'::character varying, 'run_bet'::character varying, 'legacy_bet'::character varying, 'digit_bet'::character varying])::text[])))
);

CREATE TABLE digit_bet (
    financial_market_bet_id bigint NOT NULL,
    last_digit smallint NOT NULL,
    prediction character varying(20) NOT NULL,
    CONSTRAINT chk_prediction_value CHECK (((prediction)::text = ANY ((ARRAY['match'::character varying, 'differ'::character varying])::text[])))
);

SET search_path = sequences, pg_catalog;

CREATE SEQUENCE bet_serial
    START WITH 19
    INCREMENT BY 20
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

SET search_path = bet, pg_catalog;

CREATE TABLE financial_market_bet (
    id bigint DEFAULT nextval('sequences.bet_serial'::regclass) NOT NULL,
    purchase_time timestamp without time zone DEFAULT now(),
    account_id bigint NOT NULL,
    underlying_symbol character varying(50),
    payout_price numeric,
    buy_price numeric NOT NULL,
    sell_price numeric,
    start_time timestamp without time zone,
    expiry_time timestamp without time zone,
    settlement_time timestamp without time zone,
    expiry_daily boolean DEFAULT false NOT NULL,
    is_expired boolean DEFAULT false,
    is_sold boolean DEFAULT false,
    bet_class character varying(30) NOT NULL,
    bet_type character varying(30) NOT NULL,
    remark character varying(800),
    short_code character varying(255),
    sell_time timestamp without time zone,
    fixed_expiry boolean,
    tick_count integer,
    CONSTRAINT basic_validation CHECK (((purchase_time < '2014-05-09 00:00:00'::timestamp without time zone) OR (((((((((NOT is_sold) OR (((((0)::numeric <= sell_price) AND (sell_price <= payout_price)) AND (round(sell_price, 2) = sell_price)) AND (purchase_time < sell_time))) AND ((0)::numeric < buy_price)) AND ((0)::numeric < payout_price)) AND (round(buy_price, 2) = buy_price)) AND (round(payout_price, 2) = payout_price)) AND (purchase_time <= start_time)) AND (start_time <= expiry_time)) AND (purchase_time <= settlement_time)))),
    CONSTRAINT check_sell_time_sell_price CHECK (((((is_sold AND (sell_time IS NOT NULL)) AND (sell_price IS NOT NULL)) OR (((NOT is_sold) AND (sell_time IS NULL)) AND (sell_price IS NULL))) OR (purchase_time < '2012-07-18 06:00:00'::timestamp without time zone))),
    CONSTRAINT pk_check_bet_class_value CHECK (((bet_class)::text = ANY ((ARRAY['higher_lower_bet'::character varying, 'range_bet'::character varying, 'touch_bet'::character varying, 'run_bet'::character varying, 'legacy_bet'::character varying, 'digit_bet'::character varying])::text[]))),
    CONSTRAINT pk_check_bet_params_payout_price CHECK ((((bet_class)::text = 'legacy_bet'::text) OR (payout_price IS NOT NULL))),
    CONSTRAINT pk_check_bet_params_underlying_symbol CHECK ((((bet_class)::text = 'legacy_bet'::text) OR (underlying_symbol IS NOT NULL)))
);

CREATE TABLE higher_lower_bet (
    financial_market_bet_id bigint NOT NULL,
    relative_barrier character varying(20),
    absolute_barrier numeric,
    prediction character varying(20),
    CONSTRAINT chk_prediction_value CHECK (((prediction)::text = ANY (ARRAY[('up'::character varying)::text, ('down'::character varying)::text])))
);

CREATE TABLE legacy_bet (
    financial_market_bet_id bigint NOT NULL,
    absolute_lower_barrier numeric,
    absolute_higher_barrier numeric,
    intraday_ifunless character varying(50),
    intraday_starthour character varying(10),
    intraday_leg1 character varying(10),
    intraday_midhour character varying(10),
    intraday_leg2 character varying(10),
    intraday_endhour character varying(10),
    short_code character varying(255)
);

CREATE TABLE range_bet (
    financial_market_bet_id bigint NOT NULL,
    relative_lower_barrier character varying(20),
    absolute_lower_barrier numeric,
    relative_higher_barrier character varying(20),
    absolute_higher_barrier numeric,
    prediction character varying(20),
    CONSTRAINT chk_prediction_value CHECK (((prediction)::text = ANY (ARRAY[('in'::character varying)::text, ('out'::character varying)::text])))
);

CREATE TABLE run_bet (
    financial_market_bet_id bigint NOT NULL,
    number_of_ticks integer,
    last_digit integer,
    prediction character varying(20),
    CONSTRAINT chk_prediction_value CHECK (((prediction)::text = ANY (ARRAY[('up'::character varying)::text, ('down'::character varying)::text, ('hit'::character varying)::text, ('miss'::character varying)::text])))
);

CREATE TABLE touch_bet (
    financial_market_bet_id bigint NOT NULL,
    relative_barrier character varying(20),
    absolute_barrier numeric,
    prediction character varying(20),
    CONSTRAINT chk_prediction_value CHECK (((prediction)::text = ANY (ARRAY[('touch'::character varying)::text, ('notouch'::character varying)::text])))
);

SET search_path = betonmarkets, pg_catalog;

CREATE TABLE broker_code (
    broker_code character varying(32) NOT NULL
);

SET default_with_oids = true;

CREATE TABLE client (
    loginid character varying(12) NOT NULL,
    client_password character varying(255) NOT NULL,
    first_name character varying(50) NOT NULL,
    last_name character varying(50) NOT NULL,
    email character varying(100) NOT NULL,
    allow_login boolean DEFAULT true NOT NULL,
    broker_code character varying(32) NOT NULL,
    residence character varying(100) NOT NULL,
    citizen character varying(100) NOT NULL,
    salutation character varying(30) NOT NULL,
    address_line_1 character varying(1000) NOT NULL,
    address_line_2 character varying(255) NOT NULL,
    address_city character varying(300) NOT NULL,
    address_state character varying(100) NOT NULL,
    address_postcode character varying(64) NOT NULL,
    phone character varying(255) NOT NULL,
    date_joined timestamp(0) without time zone DEFAULT now(),
    latest_environment character varying(1024) NOT NULL,
    secret_question character varying(255) NOT NULL,
    secret_answer character varying(500) NOT NULL,
    restricted_ip_address character varying(50) NOT NULL,
    gender character varying(1) NOT NULL,
    cashier_setting_password character varying(255) NOT NULL,
    date_of_birth date,
    small_timer character varying(30) DEFAULT 'yes'::character varying NOT NULL,
    fax character varying(255) NOT NULL,
    driving_license character varying(50) NOT NULL,
    comment text DEFAULT ''::text NOT NULL,
    myaffiliates_token character varying(32) DEFAULT NULL::character varying,
    myaffiliates_token_registered boolean DEFAULT false NOT NULL,
    checked_affiliate_exposures boolean DEFAULT false NOT NULL,
    custom_max_acbal integer,
    custom_max_daily_turnover integer,
    custom_max_payout integer,
    vip_since timestamp without time zone,
    payment_agent_withdrawal_expiration_date date,
    first_time_login boolean DEFAULT true,
    CONSTRAINT check_client_email_format CHECK ((((email)::text = ''::text) OR (((email)::text ~* '^[.a-z0-9!#$%&''*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&''*+/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$'::text) AND ((email)::text !~ '%00'::text)))),
    CONSTRAINT check_client_loginid_broker_eq_to_broker_field CHECK (("substring"((loginid)::text, '^[A-Z]+'::text) = (broker_code)::text)),
    CONSTRAINT check_client_loginid_format CHECK (((loginid)::text ~ '^[A-Z]{2,4}[0-9]{1,8}$'::text))
);

SET default_with_oids = false;

CREATE TABLE client_affiliate_exposure (
    id bigint DEFAULT nextval('sequences.global_serial'::regclass) NOT NULL,
    client_loginid character varying(12) NOT NULL,
    myaffiliates_token character varying(32) NOT NULL,
    exposure_record_date timestamp(0) without time zone DEFAULT now(),
    pay_for_exposure boolean DEFAULT false NOT NULL,
    myaffiliates_token_registered boolean DEFAULT false NOT NULL,
    signup_override boolean DEFAULT false NOT NULL
);

CREATE TABLE client_authentication_document (
    id bigint DEFAULT nextval('sequences.global_serial'::regclass) NOT NULL,
    document_type character varying(100) NOT NULL,
    document_format character varying(100) NOT NULL,
    document_path character varying(255) NOT NULL,
    client_loginid character varying(12) NOT NULL,
    authentication_method_code character varying(50) NOT NULL,
    expiration_date date,
    CONSTRAINT check_client_authentication_document_document_path_format CHECK (((((document_path)::text !~ '\.\.'::text) AND ((document_path)::text !~ '%00'::text)) AND ((document_path)::text !~ '[><&@#$!:|\\]'::text)))
);

CREATE TABLE client_authentication_method (
    id bigint DEFAULT nextval('sequences.global_serial'::regclass) NOT NULL,
    client_loginid character varying(12) NOT NULL,
    authentication_method_code character varying(50) NOT NULL,
    last_modified_date timestamp(0) without time zone,
    status character varying(100) NOT NULL,
    description text DEFAULT ''::text NOT NULL
);

CREATE TABLE client_lock (
    client_loginid character varying(12) NOT NULL,
    locked boolean DEFAULT false,
    description text DEFAULT ''::text,
    "time" timestamp(0) without time zone DEFAULT now()
);

CREATE TABLE client_promo_code (
    id bigint DEFAULT nextval('sequences.global_serial'::regclass) NOT NULL,
    client_loginid character varying(12) NOT NULL,
    promotion_code character varying(20) NOT NULL,
    apply_date timestamp(0) without time zone,
    status character varying(100) NOT NULL,
    mobile character varying(20) NOT NULL,
    checked_in_myaffiliates boolean DEFAULT false NOT NULL
);

CREATE TABLE client_status (
    id bigint DEFAULT nextval('sequences.global_serial'::regclass) NOT NULL,
    client_loginid character varying(12) NOT NULL,
    status_code character varying(32) NOT NULL,
    staff_name character varying(100) NOT NULL,
    reason character varying(1000) NOT NULL,
    last_modified_date timestamp(0) without time zone DEFAULT now()
);

CREATE TABLE handoff_token (
    key character varying(40) NOT NULL,
    client_loginid character varying(12),
    expires timestamp(0) without time zone,
    id bigint DEFAULT nextval('sequences.global_serial'::regclass) NOT NULL
);

CREATE TABLE login_history (
    id bigint DEFAULT nextval('sequences.global_serial'::regclass) NOT NULL,
    client_loginid character varying(12) NOT NULL,
    login_environment character varying(1024) NOT NULL,
    login_date timestamp(0) without time zone DEFAULT now(),
    login_successful boolean NOT NULL,
    login_action character varying(255) NOT NULL
);

CREATE TABLE payment_agent (
    client_loginid character varying(12) NOT NULL,
    payment_agent_name character varying(100) NOT NULL,
    url character varying(100) NOT NULL,
    email character varying(100) NOT NULL,
    phone character varying(40) NOT NULL,
    information character varying(500) NOT NULL,
    summary character varying(255) NOT NULL,
    comission_deposit real NOT NULL,
    comission_withdrawal real NOT NULL,
    is_authenticated boolean NOT NULL,
    api_ip character varying(64),
    currency_code character varying(3) NOT NULL,
    currency_code_2 character varying(3) NOT NULL,
    target_country character varying(255) DEFAULT ''::character varying NOT NULL,
    supported_banks character varying(500)
);

CREATE TABLE promo_code (
    code character varying(20) NOT NULL,
    start_date timestamp(0) without time zone,
    expiry_date timestamp(0) without time zone,
    status boolean DEFAULT true NOT NULL,
    promo_code_type character varying(100) NOT NULL,
    promo_code_config text NOT NULL,
    description character varying(255) NOT NULL,
    CONSTRAINT check_promo_code_code_format CHECK (((code)::text ~ '^[a-zA-Z0-9_\-.]+$'::text))
);

CREATE TABLE self_exclusion (
    client_loginid character varying(12) NOT NULL,
    max_balance integer,
    max_turnover integer,
    max_open_bets integer,
    exclude_until date,
    session_duration_limit integer,
    last_modified_date timestamp(0) without time zone DEFAULT now()
);

SET search_path = data_collection, pg_catalog;

CREATE TABLE exchange_rate (
    id bigint DEFAULT nextval('sequences.global_serial'::regclass) NOT NULL,
    source_currency character(3) NOT NULL,
    target_currency character(3) NOT NULL,
    date timestamp without time zone,
    rate numeric(10,4)
);

CREATE TABLE quants_bet_variables (
    financial_market_bet_id bigint NOT NULL,
    theo numeric,
    trade numeric,
    recalc numeric,
    iv numeric,
    win numeric,
    delta numeric,
    vega numeric,
    theta numeric,
    gamma numeric,
    intradaytime numeric,
    div numeric,
    "int" numeric,
    base_spread numeric,
    news_fct numeric,
    mrev_fct numeric,
    mrv_ind numeric,
    fwdst_fct numeric,
    atmf_fct numeric,
    dscrt_fct numeric,
    spot numeric,
    emp numeric,
    transaction_id bigint NOT NULL
);

SET search_path = payment, pg_catalog;

CREATE TABLE account_transfer (
    payment_id bigint NOT NULL,
    corresponding_payment_id bigint
);

CREATE TABLE affiliate_reward (
    payment_id bigint NOT NULL,
    reward_from_date date,
    reward_to_date date
);

CREATE TABLE bank_wire (
    payment_id bigint NOT NULL,
    client_name character varying(100) DEFAULT ''::character varying NOT NULL,
    bom_bank_info character varying(150) DEFAULT ''::character varying NOT NULL,
    date_received timestamp(0) without time zone,
    bank_reference character varying(50) DEFAULT ''::character varying NOT NULL,
    bank_name character varying(50) DEFAULT ''::character varying NOT NULL,
    bank_address character varying(150) DEFAULT ''::character varying NOT NULL,
    bank_account_number character varying(50) DEFAULT ''::character varying NOT NULL,
    bank_account_name character varying(50) DEFAULT ''::character varying NOT NULL,
    iban character varying(50) DEFAULT ''::character varying NOT NULL,
    sort_code character varying(150) DEFAULT ''::character varying NOT NULL,
    swift character varying(11) DEFAULT ''::character varying NOT NULL,
    aba character varying(50) DEFAULT ''::character varying NOT NULL,
    extra_info character varying(500) DEFAULT ''::character varying NOT NULL
);

CREATE TABLE currency_conversion_transfer (
    payment_id bigint NOT NULL,
    corresponding_payment_id bigint
);

CREATE TABLE doughflow (
    payment_id bigint NOT NULL,
    transaction_type character varying(15) NOT NULL,
    trace_id bigint NOT NULL,
    created_by character varying(50),
    payment_processor character varying(50) NOT NULL,
    ip_address character varying(15),
    transaction_id character varying(100),
    CONSTRAINT chk_doughflow_txn_type_valid CHECK (((transaction_type)::text = ANY (ARRAY[('deposit'::character varying)::text, ('withdrawal'::character varying)::text, ('withdrawal_reversal'::character varying)::text])))
);

CREATE TABLE free_gift (
    payment_id bigint NOT NULL,
    promotional_code character varying(50),
    reason character varying(255)
);

CREATE TABLE legacy_payment (
    payment_id bigint NOT NULL,
    legacy_type character varying(255)
);

SET search_path = sequences, pg_catalog;

CREATE SEQUENCE payment_serial
    START WITH 19
    INCREMENT BY 20
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

SET search_path = payment, pg_catalog;

CREATE TABLE payment (
    id bigint DEFAULT nextval('sequences.payment_serial'::regclass) NOT NULL,
    payment_time timestamp(0) without time zone DEFAULT now(),
    amount numeric(14,4) NOT NULL,
    payment_gateway_code character varying(50) NOT NULL,
    payment_type_code character varying(50) NOT NULL,
    status character varying(20) NOT NULL,
    account_id bigint NOT NULL,
    staff_loginid character varying(12) NOT NULL,
    remark character varying(800) DEFAULT ''::character varying NOT NULL
);

CREATE TABLE payment_agent_transfer (
    payment_id bigint NOT NULL,
    corresponding_payment_id bigint
);

CREATE TABLE payment_fee (
    payment_id bigint NOT NULL,
    corresponding_payment_id bigint
);

CREATE TABLE payment_gateway (
    code character varying(50) NOT NULL,
    description character varying(500) NOT NULL
);

CREATE TABLE payment_type (
    code character varying(50) NOT NULL,
    description character varying(500) NOT NULL
);

CREATE TABLE western_union (
    payment_id bigint NOT NULL,
    mtcn_number character varying(15) NOT NULL,
    payment_country character varying(64) NOT NULL,
    secret_answer character varying(128)
);

SET search_path = sequences, pg_catalog;

CREATE SEQUENCE account_serial
    START WITH 19
    INCREMENT BY 20
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_bft
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_cbet
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_cr
    START WITH 90000000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_em
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_fotc
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_ftb
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_mkt
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_mlt
    START WITH 90000000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_mx
    START WITH 90000000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_mxr
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_nf
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_otc
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_rcp
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_test
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_uk
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrt
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrtb
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrtc
    START WITH 90000000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrte
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrtf
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrtm
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrtmkt
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrtn
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrto
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrtotc
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrtp
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrtr
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrts
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_vrtu
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_ws
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_serial
    START WITH 1000
    INCREMENT BY 20
    MINVALUE 19
    MAXVALUE 999999999
    CACHE 1;

CREATE TABLE serials_configurations (
    id integer NOT NULL,
    start_with bigint NOT NULL,
    increment_by bigint NOT NULL,
    hostname text NOT NULL,
    database_name text NOT NULL,
    serial_name text NOT NULL
);

CREATE SEQUENCE serials_configurations_id_seq
    START WITH 19
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE serials_configurations_id_seq OWNED BY serials_configurations.id;

CREATE SEQUENCE transaction_serial
    START WITH 19
    INCREMENT BY 20
    MINVALUE 19
    NO MAXVALUE
    CACHE 1;

SET search_path = transaction, pg_catalog;

CREATE TABLE account (
    id bigint DEFAULT nextval('sequences.account_serial'::regclass) NOT NULL,
    client_loginid character varying(12) NOT NULL,
    currency_code character varying(3) NOT NULL,
    balance numeric(14,4) DEFAULT 0 NOT NULL,
    is_default boolean DEFAULT true NOT NULL,
    last_modified timestamp without time zone,
    CONSTRAINT check_no_negative_balance CHECK ((balance >= (0)::numeric))
);

CREATE TABLE transaction (
    id bigint DEFAULT nextval('sequences.transaction_serial'::regclass) NOT NULL,
    account_id bigint NOT NULL,
    transaction_time timestamp without time zone DEFAULT now(),
    amount numeric(14,4) NOT NULL,
    staff_loginid character varying(24),
    remark character varying(800),
    referrer_type character varying(20) NOT NULL,
    financial_market_bet_id bigint,
    payment_id bigint,
    action_type character varying(20) NOT NULL,
    quantity integer DEFAULT 1,
    balance_after numeric(14,4),
    CONSTRAINT chk_amount_sign_based_on_action_type CHECK ((((((((action_type)::text = 'deposit'::text) AND (amount >= (0)::numeric)) OR ((((action_type)::text = 'buy'::text) OR ((action_type)::text = 'withdrawal'::text)) AND (amount <= (0)::numeric))) OR ((action_type)::text = 'adjustment'::text)) OR ((action_type)::text = 'sell'::text)) OR ((action_type)::text = 'virtual_credit'::text))),
    CONSTRAINT chk_referrer_id_based_on_referrer_type CHECK ((((((referrer_type)::text = 'payment'::text) AND (payment_id IS NOT NULL)) OR ((referrer_type)::text = 'financial_market_bet'::text)) OR ((action_type)::text = 'virtual_credit'::text))),
    CONSTRAINT chk_transaction_field_action_type CHECK (((action_type)::text = ANY (ARRAY[('buy'::character varying)::text, ('sell'::character varying)::text, ('deposit'::character varying)::text, ('withdrawal'::character varying)::text, ('adjustment'::character varying)::text, ('virtual_credit'::character varying)::text]))),
    CONSTRAINT chk_transaction_field_referrer_type CHECK (((referrer_type)::text = ANY (ARRAY[('financial_market_bet'::character varying)::text, ('payment'::character varying)::text])))
);

SET search_path = sequences, pg_catalog;

ALTER TABLE ONLY serials_configurations ALTER COLUMN id SET DEFAULT nextval('serials_configurations_id_seq'::regclass);

SET search_path = bet, pg_catalog;

ALTER TABLE ONLY bet_dictionary
    ADD CONSTRAINT pk_bet_dictionary PRIMARY KEY (id);

ALTER TABLE ONLY digit_bet
    ADD CONSTRAINT pk_digit_bet PRIMARY KEY (financial_market_bet_id);

ALTER TABLE ONLY financial_market_bet
    ADD CONSTRAINT pk_financial_market_bet PRIMARY KEY (id);

ALTER TABLE ONLY higher_lower_bet
    ADD CONSTRAINT pk_higher_lower_bet PRIMARY KEY (financial_market_bet_id);

ALTER TABLE ONLY legacy_bet
    ADD CONSTRAINT pk_legacy_bet PRIMARY KEY (financial_market_bet_id);

ALTER TABLE ONLY range_bet
    ADD CONSTRAINT pk_range_bet PRIMARY KEY (financial_market_bet_id);

ALTER TABLE ONLY run_bet
    ADD CONSTRAINT pk_run_bet PRIMARY KEY (financial_market_bet_id);

ALTER TABLE ONLY touch_bet
    ADD CONSTRAINT pk_touch_bet PRIMARY KEY (financial_market_bet_id);

ALTER TABLE ONLY bet_dictionary
    ADD CONSTRAINT unique_bet_type UNIQUE (bet_type);

SET search_path = betonmarkets, pg_catalog;

ALTER TABLE ONLY broker_code
    ADD CONSTRAINT broker_code_pkey PRIMARY KEY (broker_code);

ALTER TABLE ONLY client_affiliate_exposure
    ADD CONSTRAINT client_affiliate_exposure_pkey PRIMARY KEY (id);

ALTER TABLE ONLY client_lock
    ADD CONSTRAINT client_lock_pkey PRIMARY KEY (client_loginid);

ALTER TABLE ONLY handoff_token
    ADD CONSTRAINT handoff_token_pkey PRIMARY KEY (id);

ALTER TABLE ONLY client
    ADD CONSTRAINT pk_client PRIMARY KEY (loginid);

ALTER TABLE ONLY client_authentication_document
    ADD CONSTRAINT pk_client_authentication_document PRIMARY KEY (id);

ALTER TABLE ONLY client_authentication_method
    ADD CONSTRAINT pk_client_authentication_method PRIMARY KEY (id);

ALTER TABLE ONLY client_promo_code
    ADD CONSTRAINT pk_client_promo_code PRIMARY KEY (id);

ALTER TABLE ONLY client_status
    ADD CONSTRAINT pk_client_status PRIMARY KEY (id);

ALTER TABLE ONLY login_history
    ADD CONSTRAINT pk_login_history PRIMARY KEY (id);

ALTER TABLE ONLY payment_agent
    ADD CONSTRAINT pk_payment_agent PRIMARY KEY (client_loginid);

ALTER TABLE ONLY promo_code
    ADD CONSTRAINT pk_promo_code PRIMARY KEY (code);

ALTER TABLE ONLY self_exclusion
    ADD CONSTRAINT pk_self_exclusion PRIMARY KEY (client_loginid);

ALTER TABLE ONLY client_authentication_method
    ADD CONSTRAINT uk_client_authentication_method UNIQUE (client_loginid, authentication_method_code);

ALTER TABLE ONLY client_promo_code
    ADD CONSTRAINT uk_client_promo_code_client_loginid UNIQUE (client_loginid);

ALTER TABLE ONLY client_status
    ADD CONSTRAINT uk_client_status UNIQUE (client_loginid, status_code);

ALTER TABLE ONLY handoff_token
    ADD CONSTRAINT uk_handoff_token_key UNIQUE (key);

SET search_path = data_collection, pg_catalog;

ALTER TABLE ONLY exchange_rate
    ADD CONSTRAINT exchange_rate_source_currency_key UNIQUE (source_currency, target_currency, date);

ALTER TABLE ONLY exchange_rate
    ADD CONSTRAINT pk_exchange_rate PRIMARY KEY (id);

ALTER TABLE ONLY quants_bet_variables
    ADD CONSTRAINT quants_bet_variables_pkey PRIMARY KEY (transaction_id);

SET search_path = payment, pg_catalog;

ALTER TABLE ONLY account_transfer
    ADD CONSTRAINT pk_account_transfer PRIMARY KEY (payment_id);

ALTER TABLE ONLY affiliate_reward
    ADD CONSTRAINT pk_affiliate_reward PRIMARY KEY (payment_id);

ALTER TABLE ONLY bank_wire
    ADD CONSTRAINT pk_bank_wire PRIMARY KEY (payment_id);

ALTER TABLE ONLY currency_conversion_transfer
    ADD CONSTRAINT pk_currency_conversion_transfer PRIMARY KEY (payment_id);

ALTER TABLE ONLY doughflow
    ADD CONSTRAINT pk_doughflow PRIMARY KEY (payment_id);

ALTER TABLE ONLY free_gift
    ADD CONSTRAINT pk_free_gift PRIMARY KEY (payment_id);

ALTER TABLE ONLY legacy_payment
    ADD CONSTRAINT pk_legacy_payment PRIMARY KEY (payment_id);

ALTER TABLE ONLY payment
    ADD CONSTRAINT pk_payment PRIMARY KEY (id);

ALTER TABLE ONLY payment_agent_transfer
    ADD CONSTRAINT pk_payment_agent_transfer PRIMARY KEY (payment_id);

ALTER TABLE ONLY payment_fee
    ADD CONSTRAINT pk_payment_fee PRIMARY KEY (payment_id);

ALTER TABLE ONLY payment_gateway
    ADD CONSTRAINT pk_payment_gateway PRIMARY KEY (code);

ALTER TABLE ONLY payment_type
    ADD CONSTRAINT pk_payment_type PRIMARY KEY (code);

ALTER TABLE ONLY western_union
    ADD CONSTRAINT pk_western_union PRIMARY KEY (payment_id);

SET search_path = sequences, pg_catalog;

ALTER TABLE ONLY serials_configurations
    ADD CONSTRAINT pk_unique_key UNIQUE (start_with, increment_by, database_name, hostname, serial_name);

ALTER TABLE ONLY serials_configurations
    ADD CONSTRAINT serials_configurations_pkey PRIMARY KEY (id);

SET search_path = transaction, pg_catalog;

ALTER TABLE ONLY account
    ADD CONSTRAINT pk_account PRIMARY KEY (id);

ALTER TABLE ONLY transaction
    ADD CONSTRAINT pk_transaction PRIMARY KEY (id);

ALTER TABLE ONLY account
    ADD CONSTRAINT uk_account_client_loginid_currency_code UNIQUE (client_loginid, currency_code);

SET search_path = audit, pg_catalog;

CREATE INDEX idx_account_stamp ON account USING btree (stamp);

CREATE INDEX idx_account_transfer_stamp ON account_transfer USING btree (stamp);

CREATE INDEX idx_affiliate_reward_stamp ON affiliate_reward USING btree (stamp);

CREATE INDEX idx_affiliate_stamp ON affiliate USING btree (stamp);

CREATE INDEX idx_bank_wire_stamp ON bank_wire USING btree (stamp);

CREATE INDEX idx_client_authentication_document_stamp ON client_authentication_document USING btree (stamp);

CREATE INDEX idx_client_authentication_method_stamp ON client_authentication_method USING btree (stamp);

CREATE INDEX idx_client_promo_code_stamp ON client_promo_code USING btree (stamp);

CREATE INDEX idx_client_stamp ON client USING btree (stamp);

CREATE INDEX idx_client_status_stamp ON client_status USING btree (stamp);

CREATE INDEX idx_currency_conversion_transfer_stamp ON currency_conversion_transfer USING btree (stamp);

CREATE INDEX idx_doughflow_stamp ON doughflow USING btree (stamp);

CREATE INDEX idx_financial_market_bet_stamp ON financial_market_bet USING btree (stamp);

CREATE INDEX idx_free_gift_stamp ON free_gift USING btree (stamp);

CREATE INDEX idx_higher_lower_bet_stamp ON higher_lower_bet USING btree (stamp);

CREATE INDEX idx_legacy_bet_stamp ON legacy_bet USING btree (stamp);

CREATE INDEX idx_legacy_payment_stamp ON legacy_payment USING btree (stamp);

CREATE INDEX idx_login_history_stamp ON login_history USING btree (stamp);

CREATE INDEX idx_payment_agent_stamp ON payment_agent USING btree (stamp);

CREATE INDEX idx_payment_agent_transfer_stamp ON payment_agent_transfer USING btree (stamp);

CREATE INDEX idx_payment_fee_stamp ON payment_fee USING btree (stamp);

CREATE INDEX idx_payment_stamp ON payment USING btree (stamp);

CREATE INDEX idx_promo_code_stamp ON promo_code USING btree (stamp);

CREATE INDEX idx_range_bet_stamp ON range_bet USING btree (stamp);

CREATE INDEX idx_run_bet_stamp ON run_bet USING btree (stamp);

CREATE INDEX idx_self_exclusion_stamp ON self_exclusion USING btree (stamp);

CREATE INDEX idx_touch_bet_stamp ON touch_bet USING btree (stamp);

CREATE INDEX idx_transaction_stamp ON transaction USING btree (stamp);

CREATE INDEX idx_western_union_stamp ON western_union USING btree (stamp);

SET search_path = bet, pg_catalog;

CREATE INDEX financial_market_bet_account_id_is_sold_bet_class_idx ON financial_market_bet USING btree (account_id, is_sold, bet_class);

CREATE INDEX financial_market_bet_account_id_purchase_time_bet_class_idx ON financial_market_bet USING btree (account_id, date(purchase_time), bet_class);

CREATE INDEX financial_market_bet_account_id_purchase_time_idx ON financial_market_bet USING btree (account_id, purchase_time DESC);

CREATE INDEX financial_market_ready_to_sell_idx ON financial_market_bet USING btree (expiry_time) WHERE (is_sold IS FALSE);

CREATE INDEX fmb_purchase_time_idx ON financial_market_bet USING btree (purchase_time);

CREATE INDEX fmb_sell_time_idx ON financial_market_bet USING btree (sell_time);

SET search_path = betonmarkets, pg_catalog;

CREATE INDEX client_email_idx ON client USING btree (email);

CREATE UNIQUE INDEX client_unique_email_address ON client USING btree (lower((email)::text), broker_code) WHERE ((((date_joined > '2013-08-29 08:00:00'::timestamp without time zone) AND ((email)::text !~~ '%@regentmarkets.com'::text)) AND ((email)::text !~~ '%@binary.com'::text)) AND (vip_since IS NULL));

CREATE INDEX idx_authentication_document_client ON client_authentication_document USING btree (client_loginid);

CREATE INDEX login_history_client_login_idx ON login_history USING btree (client_loginid);

CREATE INDEX login_history_loginid_login_date_desc_idx ON login_history USING btree (client_loginid, login_date DESC);

SET search_path = payment, pg_catalog;

CREATE INDEX payment_account_id_payment_time_status_payment_gateway_code_idx ON payment USING btree (account_id, payment_time DESC NULLS LAST, status, payment_gateway_code);

CREATE INDEX payment_account_id_payment_time_status_payment_type_code_idx ON payment USING btree (account_id, payment_time DESC NULLS LAST, status, payment_type_code);

CREATE INDEX payment_payment_time_status_payment_type_code_idx ON payment USING btree (payment_time DESC NULLS LAST, status, payment_type_code);

SET search_path = transaction, pg_catalog;

CREATE UNIQUE INDEX account_unique_client_loginid_currency_code ON account USING btree (client_loginid, is_default) WHERE (is_default = true);

CREATE UNIQUE INDEX chk_dup_sell_idx ON transaction USING btree (financial_market_bet_id) WHERE (((action_type)::text = 'sell'::text) AND (transaction_time >= '2012-07-18 06:00:00'::timestamp without time zone));

CREATE INDEX transaction_acc_id_fmb_id_transaction_time_idx ON transaction USING btree (account_id, financial_market_bet_id, transaction_time DESC NULLS LAST) WHERE (financial_market_bet_id IS NOT NULL);

CREATE INDEX transaction_acc_id_payment_id_transaction_time_idx ON transaction USING btree (account_id, payment_id, transaction_time DESC NULLS LAST) WHERE (payment_id IS NOT NULL);

CREATE INDEX transaction_acc_id_txn_time_desc_idx ON transaction USING btree (account_id, transaction_time DESC);

CREATE INDEX transaction_account_id_amount_idx ON transaction USING btree (account_id, amount);

CREATE INDEX transaction_account_id_financial_market_bet_id_transaction_time ON transaction USING btree (account_id, financial_market_bet_id, transaction_time DESC NULLS LAST);

CREATE INDEX transaction_account_id_payment_id_transaction_time_idx ON transaction USING btree (account_id, payment_id, transaction_time DESC NULLS LAST);

CREATE INDEX transaction_account_id_transaction_time_action_type_idx ON transaction USING btree (account_id, date(transaction_time), action_type);

CREATE INDEX transaction_transaction_fmb_id_idx ON transaction USING btree (financial_market_bet_id);

CREATE INDEX transaction_transaction_payment_id_idx ON transaction USING btree (payment_id);

CREATE INDEX transaction_transaction_time_action_type_idx ON transaction USING btree (transaction_time, action_type);

CREATE INDEX transaction_txntime_trunct_to_day_idx ON transaction USING btree (date_trunc('day'::text, transaction_time));

SET search_path = bet, pg_catalog;

CREATE TRIGGER prevent_action BEFORE DELETE ON financial_market_bet FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

CREATE TRIGGER prevent_action BEFORE DELETE ON higher_lower_bet FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

CREATE TRIGGER prevent_action BEFORE DELETE ON range_bet FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

CREATE TRIGGER prevent_action BEFORE DELETE ON run_bet FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

CREATE TRIGGER prevent_action BEFORE DELETE ON touch_bet FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

CREATE TRIGGER prevent_action BEFORE DELETE ON digit_bet FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

SET search_path = betonmarkets, pg_catalog;

SET search_path = data_collection, pg_catalog;

SET search_path = payment, pg_catalog;

CREATE TRIGGER prevent_action BEFORE DELETE ON payment FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

CREATE TRIGGER prevent_action BEFORE DELETE ON doughflow FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

CREATE TRIGGER prevent_action BEFORE DELETE ON legacy_payment FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

CREATE TRIGGER prevent_action BEFORE DELETE ON payment_agent_transfer FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

CREATE TRIGGER prevent_action BEFORE DELETE ON currency_conversion_transfer FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

SET search_path = transaction, pg_catalog;

CREATE TRIGGER prevent_action BEFORE DELETE ON account FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

SET search_path = bet, pg_catalog;

ALTER TABLE ONLY digit_bet
    ADD CONSTRAINT fk_digit_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id) REFERENCES financial_market_bet(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY financial_market_bet
    ADD CONSTRAINT fk_financial_market_bet_account_id FOREIGN KEY (account_id) REFERENCES transaction.account(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY financial_market_bet
    ADD CONSTRAINT fk_fmb_bet_type FOREIGN KEY (bet_type) REFERENCES bet_dictionary(bet_type) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY higher_lower_bet
    ADD CONSTRAINT fk_higher_lower_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id) REFERENCES financial_market_bet(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY legacy_bet
    ADD CONSTRAINT fk_legacy_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id) REFERENCES financial_market_bet(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY range_bet
    ADD CONSTRAINT fk_range_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id) REFERENCES financial_market_bet(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY run_bet
    ADD CONSTRAINT fk_run_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id) REFERENCES financial_market_bet(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY touch_bet
    ADD CONSTRAINT fk_touch_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id) REFERENCES financial_market_bet(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

SET search_path = betonmarkets, pg_catalog;

ALTER TABLE ONLY client_authentication_document
    ADD CONSTRAINT authentication_document_client_fk FOREIGN KEY (client_loginid) REFERENCES client(loginid) ON DELETE RESTRICT;

ALTER TABLE ONLY client_affiliate_exposure
    ADD CONSTRAINT fk_client_affiliate_exposure_client_loginid FOREIGN KEY (client_loginid) REFERENCES client(loginid) ON UPDATE CASCADE ON DELETE RESTRICT;

ALTER TABLE ONLY client_authentication_method
    ADD CONSTRAINT fk_client_authentication_method_client_loginid FOREIGN KEY (client_loginid) REFERENCES client(loginid) ON UPDATE CASCADE ON DELETE RESTRICT;

ALTER TABLE ONLY client
    ADD CONSTRAINT fk_client_broker_code FOREIGN KEY (broker_code) REFERENCES broker_code(broker_code) ON UPDATE CASCADE ON DELETE RESTRICT;

ALTER TABLE ONLY client_promo_code
    ADD CONSTRAINT fk_client_promo_code_client_loginid FOREIGN KEY (client_loginid) REFERENCES client(loginid) ON UPDATE CASCADE ON DELETE RESTRICT;

ALTER TABLE ONLY client_status
    ADD CONSTRAINT fk_client_status_client_loginid FOREIGN KEY (client_loginid) REFERENCES client(loginid) ON UPDATE CASCADE ON DELETE RESTRICT;

ALTER TABLE ONLY login_history
    ADD CONSTRAINT fk_login_history_client_loginid FOREIGN KEY (client_loginid) REFERENCES client(loginid) ON UPDATE CASCADE ON DELETE RESTRICT;

ALTER TABLE ONLY payment_agent
    ADD CONSTRAINT fk_payment_agent_client_loginid FOREIGN KEY (client_loginid) REFERENCES client(loginid) ON UPDATE CASCADE ON DELETE RESTRICT;

ALTER TABLE ONLY self_exclusion
    ADD CONSTRAINT fk_self_exclusion_client_loginid FOREIGN KEY (client_loginid) REFERENCES client(loginid) ON UPDATE CASCADE ON DELETE RESTRICT;

SET search_path = data_collection, pg_catalog;

ALTER TABLE ONLY quants_bet_variables
    ADD CONSTRAINT fk_quants_bet_variables_financial_market_bet_id FOREIGN KEY (financial_market_bet_id) REFERENCES bet.financial_market_bet(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY quants_bet_variables
    ADD CONSTRAINT fk_quants_bet_variables_transaction_id FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

SET search_path = payment, pg_catalog;

ALTER TABLE ONLY account_transfer
    ADD CONSTRAINT fk_account_transfer_corresponding_payment_id FOREIGN KEY (corresponding_payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY account_transfer
    ADD CONSTRAINT fk_account_transfer_payment_id FOREIGN KEY (payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY affiliate_reward
    ADD CONSTRAINT fk_affiliate_reward_payment_id FOREIGN KEY (payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY bank_wire
    ADD CONSTRAINT fk_bank_wire_payment_id FOREIGN KEY (payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY currency_conversion_transfer
    ADD CONSTRAINT fk_currency_conversion_transfer_corresponding_payment_id FOREIGN KEY (corresponding_payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY currency_conversion_transfer
    ADD CONSTRAINT fk_currency_conversion_transfer_payment_id FOREIGN KEY (payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY doughflow
    ADD CONSTRAINT fk_doughflow_payment_id FOREIGN KEY (payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY free_gift
    ADD CONSTRAINT fk_free_gift_payment_id FOREIGN KEY (payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY legacy_payment
    ADD CONSTRAINT fk_legacy_payment_payment_id FOREIGN KEY (payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY payment
    ADD CONSTRAINT fk_payment_account_id FOREIGN KEY (account_id) REFERENCES transaction.account(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY payment_agent_transfer
    ADD CONSTRAINT fk_payment_agent_transfer_corresponding_payment_id FOREIGN KEY (corresponding_payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY payment_agent_transfer
    ADD CONSTRAINT fk_payment_agent_transfer_payment_id FOREIGN KEY (payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY payment_fee
    ADD CONSTRAINT fk_payment_fee_corresponding_payment_id FOREIGN KEY (corresponding_payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY payment_fee
    ADD CONSTRAINT fk_payment_fee_payment_id FOREIGN KEY (payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY payment
    ADD CONSTRAINT fk_payment_payment_gateway_code FOREIGN KEY (payment_gateway_code) REFERENCES payment_gateway(code) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY payment
    ADD CONSTRAINT fk_payment_payment_type_code FOREIGN KEY (payment_type_code) REFERENCES payment_type(code) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY western_union
    ADD CONSTRAINT fk_western_union_payment_id FOREIGN KEY (payment_id) REFERENCES payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

SET search_path = transaction, pg_catalog;

ALTER TABLE ONLY account
    ADD CONSTRAINT fk_account_loginid FOREIGN KEY (client_loginid) REFERENCES betonmarkets.client(loginid) MATCH FULL;

ALTER TABLE ONLY transaction
    ADD CONSTRAINT fk_transaction_account_id FOREIGN KEY (account_id) REFERENCES account(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY transaction
    ADD CONSTRAINT fk_transaction_financial_market_bet_id FOREIGN KEY (financial_market_bet_id) REFERENCES bet.financial_market_bet(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY transaction
    ADD CONSTRAINT fk_transaction_payment_id FOREIGN KEY (payment_id) REFERENCES payment.payment(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION last_agg(anyelement, anyelement) RETURNS anyelement
    LANGUAGE sql IMMUTABLE STRICT
    AS $_$
        SELECT $2;
$_$;


CREATE AGGREGATE last(anyelement) (
    SFUNC = last_agg,
    STYPE = anyelement
);


SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION first_agg(anyelement, anyelement) RETURNS anyelement
    LANGUAGE sql IMMUTABLE STRICT
    AS $_$
        SELECT $1;
$_$;


CREATE AGGREGATE first(anyelement) (
    SFUNC = first_agg,
    STYPE = anyelement
);

SET search_path = audit, pg_catalog;

CREATE OR REPLACE FUNCTION check_table_changes_before_change_and_backup_in_audit() RETURNS trigger
    LANGUAGE plperlu SECURITY DEFINER
    AS $_X$
    use utf8;
    use Encode;


    my @args = @{$_TD->{args}};
    my $allow_multipe_changes = $args[0];


    # This valiralbe will be set when we change the NEW fields and at the end we must returm MODIFY if it is set.
    my $data_modify = 0;

    $rv = spi_exec_query('SELECT inet_client_addr()');
    my $inet_client_addr = $rv->{rows}[0]->{inet_client_addr};

    $rv = spi_exec_query('SELECT inet_client_port()');
    my $inet_client_port = $rv->{rows}[0]->{inet_client_port};

    $rv = spi_exec_query('SELECT transaction_timestamp()');
    my $transaction_timestamp = $rv->{rows}[0]->{transaction_timestamp};

    $rv = spi_exec_query('SELECT session_user');
    my $session_user = $rv->{rows}[0]->{session_user};


    my $tablename = $_TD->{table_name};
    my $tableschema = $_TD->{table_schema};
    my $operation = $_TD->{event};

    # Check if command is changing more than one row at a time.
    # Also rpelicator user is allow to do more than just one change in rows. Bucardo do that.
    if ( ($operation eq 'UPDATE'  or $operation eq 'DELETE') and $allow_multipe_changes ne 'allow_multipe_changes' and $session_user ne 'replicator' )
    {
        $rv = spi_exec_query("SELECT count(*) as number_of_rows_affected_by_command FROM audit.$tablename WHERE operation = '$operation' and stamp = transaction_timestamp() and (client_addr = inet_client_addr() or inet_client_port() is null) and (client_port = inet_client_port()  or inet_client_port() is null) limit 2");
        if ( $rv->{rows}[0]->{number_of_rows_affected_by_command} > 1)
        {
            elog(ERROR,"SERIOUS PROBLEM: Command [$operation] changing more than one rows in table [$tableschema.$tablename] from ip [$inet_client_addr] port [$inet_client_port] time [$transaction_timestamp].");
            return "SKIP";
        }
    }

    # http://archives.postgresql.org/pgsql-novice/2006-08/msg00196.php
    $rv = spi_exec_query(" SELECT * from audit.get_sorted_table_attributes('$tableschema', '$tablename')  as s(attnum TEXT,attname  TEXT,typname  TEXT,attlen  TEXT, atttypmod TEXT,attnotnull  TEXT);");
    my $attribs_count = scalar @{$rv->{rows}};
    my @attribs_array = @{$rv->{rows}};
    my @attribs_type = ('varchar', 'timestamp', 'text', 'cidr', 'int4'); # 5+
    my $attribs_insert_fields_list = 'operation , stamp, pg_userid, client_addr, client_port';
    my $attribs_insert_values_list = '$1, $2, $3, $4, $5';
    my @attribs_value_old=($operation, $transaction_timestamp, $session_user, $inet_client_addr, $inet_client_port);
    my @attribs_value_new=($operation, $transaction_timestamp, $session_user, $inet_client_addr, $inet_client_port);
    for(my $i=0; $i<$attribs_count;$i++)
    {
        $attribs_insert_fields_list .= ', '.$attribs_array[$i]->{attname};
        $attribs_insert_values_list .= ', $'.($i+1+5);
        push @attribs_type , $attribs_array[$i]->{typname};
        push @attribs_value_old , ${$_TD->{old}}{$attribs_array[$i]->{attname}};
        push @attribs_value_new , ${$_TD->{new}}{$attribs_array[$i]->{attname}};
    }


    #backup the changes data in audit tables
    my $plan = spi_prepare("INSERT INTO audit.$tablename ($attribs_insert_fields_list) values ($attribs_insert_values_list)", @attribs_type);
    if ($operation eq 'INSERT')
    {
        spi_exec_prepared($plan, @attribs_value_new);
    }
    else
    {
        # By saving the old changes on UPDATEs we make sure if we trunk the audit table for any reason
        # or we start the audit function not at start, we will have alway the complete changes on every update.
        # It mean atleast for each update new one is main table and old one in audit table.
        spi_exec_prepared($plan, @attribs_value_old);
    }
    spi_freeplan( $plan);


    if ($data_modify)
    {
        return 'MODIFY';
    }
    else
    {
        return ;
    }
$_X$;


CREATE TRIGGER check_table_changes_before_change_and_backup_in_audit BEFORE INSERT OR DELETE OR UPDATE ON client FOR EACH ROW EXECUTE PROCEDURE audit.check_table_changes_before_change_and_backup_in_audit();
CREATE TRIGGER check_table_changes_before_change_and_backup_in_audit BEFORE INSERT OR DELETE OR UPDATE ON promo_code FOR EACH ROW EXECUTE PROCEDURE audit.check_table_changes_before_change_and_backup_in_audit();
CREATE TRIGGER check_table_changes_before_change_and_backup_in_audit BEFORE INSERT OR DELETE OR UPDATE ON client_promo_code FOR EACH ROW EXECUTE PROCEDURE audit.check_table_changes_before_change_and_backup_in_audit();
CREATE TRIGGER check_table_changes_before_change_and_backup_in_audit BEFORE INSERT OR DELETE OR UPDATE ON payment_agent FOR EACH ROW EXECUTE PROCEDURE audit.check_table_changes_before_change_and_backup_in_audit();
CREATE TRIGGER check_table_changes_before_change_and_backup_in_audit BEFORE INSERT OR DELETE OR UPDATE ON client_status FOR EACH ROW EXECUTE PROCEDURE audit.check_table_changes_before_change_and_backup_in_audit();
CREATE TRIGGER check_table_changes_before_change_and_backup_in_audit BEFORE INSERT OR DELETE OR UPDATE ON client_authentication_method FOR EACH ROW EXECUTE PROCEDURE audit.check_table_changes_before_change_and_backup_in_audit();
CREATE TRIGGER check_table_changes_before_change_and_backup_in_audit BEFORE INSERT OR DELETE OR UPDATE ON client_authentication_document FOR EACH ROW EXECUTE PROCEDURE audit.check_table_changes_before_change_and_backup_in_audit();
CREATE TRIGGER check_table_changes_before_change_and_backup_in_audit BEFORE INSERT OR DELETE OR UPDATE ON self_exclusion FOR EACH ROW EXECUTE PROCEDURE audit.check_table_changes_before_change_and_backup_in_audit();




SET search_path = transaction, pg_catalog;

CREATE OR REPLACE FUNCTION calculate_balance_on_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- This single row update also serves as lock. Because all concurrent
    -- transactions affecting the same account are serialized here, the
    -- multi-row updates below cannot dead-lock.
    UPDATE transaction.account
       SET balance = balance + NEW.amount - OLD.amount,
           last_modified=NOW()
     WHERE id = NEW.account_id;

    -- This is not optimized because UPDATEs and DELETEs are actually forbidden
    -- on this table.
    -- We first perform a DELETE followed by an INSERT, so to say.

    IF OLD.amount <> 0 THEN
        UPDATE transaction.transaction t
           SET balance_after = balance_after - OLD.amount
         WHERE t.account_id = OLD.account_id
           AND t.id <> OLD.id
           AND (t.transaction_time > OLD.transaction_time
                OR t.transaction_time = OLD.transaction_time AND t.id > OLD.id);
    END IF;

    -- now transaction.transaction's state is as if we deleted OLD.

    SELECT INTO NEW.balance_after t.balance_after + NEW.amount
      FROM (SELECT t2.balance_after
              FROM (SELECT t3.balance_after
                      FROM transaction.transaction t3
                     WHERE t3.account_id = NEW.account_id
                       AND t3.transaction_time = NEW.transaction_time
                       AND t3.id < NEW.id
                       AND t3.id <> OLD.id
                     ORDER BY t3.id DESC
                     LIMIT 1) t2
             UNION ALL
            SELECT t4.balance_after
              FROM (SELECT t5.balance_after
                      FROM transaction.transaction t5
                     WHERE t5.account_id = NEW.account_id
                       AND t5.transaction_time = (SELECT max(transaction_time)
                                                    FROM transaction.transaction
                                                   WHERE account_id = NEW.account_id
                                                     AND transaction_time < NEW.transaction_time)
                       AND t5.id <> OLD.id
                     ORDER BY t5.id DESC
                     LIMIT 1) t4
             LIMIT 1) t;

    IF NOT FOUND THEN NEW.balance_after := NEW.amount; END IF;

    IF NEW.amount <> 0 THEN
        UPDATE transaction.transaction t
           SET balance_after = balance_after + NEW.amount
         WHERE t.account_id = NEW.account_id
           AND t.id <> OLD.id
           AND (t.transaction_time > NEW.transaction_time
                OR t.transaction_time = NEW.transaction_time AND t.id > NEW.id);
    END IF;

    RETURN NEW;
END;
$$;


CREATE TRIGGER calculate_balance_update BEFORE UPDATE OF account_id, amount, id, transaction_time ON transaction FOR EACH ROW EXECUTE PROCEDURE calculate_balance_on_update();


SET search_path = transaction, pg_catalog;

CREATE OR REPLACE FUNCTION calculate_balance_on_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- This single row update also serves as mutex. Because all concurrent
    -- transactions affecting the same account are serialized here, the
    -- multi-row updates below cannot dead-lock.
    UPDATE transaction.account
       SET balance = balance + NEW.amount,
           last_modified = NOW()
     WHERE id = NEW.account_id;

    SELECT INTO NEW.balance_after t.balance_after + NEW.amount
      FROM (SELECT t2.balance_after
              FROM (SELECT t3.balance_after
                      FROM transaction.transaction t3
                     WHERE t3.account_id = NEW.account_id
                       AND t3.transaction_time = NEW.transaction_time
                       AND t3.id < NEW.id
                     ORDER BY t3.id DESC
                     LIMIT 1) t2
             UNION ALL
            SELECT t4.balance_after
              FROM (SELECT t5.balance_after
                      FROM transaction.transaction t5
                     WHERE t5.account_id = NEW.account_id
                       AND t5.transaction_time = (SELECT max(transaction_time)
                                                    FROM transaction.transaction
                                                   WHERE account_id = NEW.account_id
                                                     AND transaction_time < NEW.transaction_time)
                     ORDER BY t5.id DESC
                     LIMIT 1) t4
             LIMIT 1) t;
    IF NOT FOUND THEN NEW.balance_after := NEW.amount; END IF;

    IF NEW.amount <> 0 THEN
        UPDATE transaction.transaction t
           SET balance_after = balance_after + NEW.amount
         WHERE t.account_id = NEW.account_id
           AND (t.transaction_time > NEW.transaction_time
                OR (t.transaction_time = NEW.transaction_time AND t.id > NEW.id));
    END IF;

    RETURN NEW;
END;
$$;


CREATE TRIGGER calculate_balance_insert BEFORE INSERT ON transaction FOR EACH ROW EXECUTE PROCEDURE calculate_balance_on_insert();


SET search_path = transaction, pg_catalog;

CREATE OR REPLACE FUNCTION calculate_balance_on_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- This single row update also serves as mutex. Because all concurrent
    -- transactions affecting the same account are serialized here, the
    -- multi-row updates below cannot dead-lock.
    UPDATE transaction.account
       SET balance = balance - OLD.amount,
           last_modified = NOW()
     WHERE id = OLD.account_id;

    IF OLD.amount <> 0 THEN
        UPDATE transaction.transaction t
           SET balance_after = balance_after - OLD.amount
         WHERE t.account_id = OLD.account_id
           AND t.id <> OLD.id
           AND (t.transaction_time > OLD.transaction_time
                OR t.transaction_time = OLD.transaction_time AND t.id > OLD.id);
    END IF;

    RETURN OLD;
END;
$$;


CREATE TRIGGER calculate_balance_delete BEFORE DELETE ON transaction FOR EACH ROW EXECUTE PROCEDURE calculate_balance_on_delete();



SET search_path = betonmarkets, pg_catalog;

CREATE OR REPLACE FUNCTION assert_last_modified_date() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
        BEGIN
            NEW.last_modified_date = now();
            RETURN NEW;
        END;
    $$;


CREATE TRIGGER assert_last_modified_date BEFORE INSERT OR UPDATE ON client_authentication_method FOR EACH ROW EXECUTE PROCEDURE assert_last_modified_date();
CREATE TRIGGER assert_last_modified_date BEFORE INSERT OR UPDATE ON client_status FOR EACH ROW EXECUTE PROCEDURE assert_last_modified_date();
CREATE TRIGGER assert_last_modified_date BEFORE INSERT OR UPDATE ON self_exclusion FOR EACH ROW EXECUTE PROCEDURE assert_last_modified_date();


-- INIT DATA

SET search_path = bet, pg_catalog;

INSERT INTO bet_dictionary VALUES (77380341, 'FLASHU', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380361, 'INTRADU', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380381, 'DOUBLEUP', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380401, 'FLASHD', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380421, 'INTRADD', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380441, 'DOUBLEDOWN', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380461, 'CALL', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380481, 'PUT', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380501, 'TWOFORONEUP', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380521, 'TWOFORWARDUP', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380541, 'TWOFORONEDOWN', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380561, 'TWOFORWARDDOWN', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (77380581, 'ONETOUCH', false, 'touch_bet');
INSERT INTO bet_dictionary VALUES (77380601, 'NOTOUCH', true, 'touch_bet');
INSERT INTO bet_dictionary VALUES (77380621, 'RANGE', true, 'range_bet');
INSERT INTO bet_dictionary VALUES (77380641, 'UPORDOWN', true, 'range_bet');
INSERT INTO bet_dictionary VALUES (77380661, 'EXPIRYRANGE', true, 'range_bet');
INSERT INTO bet_dictionary VALUES (77380681, 'EXPIRYMISS', true, 'range_bet');
INSERT INTO bet_dictionary VALUES (77380701, 'RUNBET_DIGIT', false, 'run_bet');
INSERT INTO bet_dictionary VALUES (77380721, 'RUNBET_TENPCT', false, 'run_bet');
INSERT INTO bet_dictionary VALUES (77380741, 'RUNBET_DOUBLEUP', false, 'run_bet');
INSERT INTO bet_dictionary VALUES (77380761, 'RUNBET_DOUBLEDOWN', false, 'run_bet');
INSERT INTO bet_dictionary VALUES (77380781, 'CLUB', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77380801, 'SPREADUP', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77380821, 'SPREADDOWN', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77380841, 'DOUBLEDBL', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77380861, 'BEARSTOP', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77380881, 'DOUBLECONTRA', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77380901, 'DOUBLEONETOUCH', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77380921, 'BULLSTOP', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77380941, 'BULLPROFIT', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77380961, 'BEARPROFIT', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77380981, 'LIMCALL', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381001, 'LIMPUT', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381021, 'CUTCALL', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381041, 'CUTPUT', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381061, 'KNOCKOUTCALLUP', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381081, 'KNOCKOUTPUTDOWN', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381101, 'POOL', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381121, 'RUNBET_RUNNINGEVEN', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381141, 'RUNBET_RUNNINGODD', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381161, 'RUNBET_JACK', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381181, 'RUNBET_PLAT', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (77381201, 'OLD_MISC_BET', NULL, 'legacy_bet');
INSERT INTO bet_dictionary VALUES (263276281, 'DIGITMATCH', false, 'digit_bet');
INSERT INTO bet_dictionary VALUES (263276301, 'DIGITDIFF', false, 'digit_bet');
INSERT INTO bet_dictionary VALUES (270744341, 'ASIANU', false, 'higher_lower_bet');
INSERT INTO bet_dictionary VALUES (270744361, 'ASIAND', false, 'higher_lower_bet');



SET search_path = payment, pg_catalog;

--
-- Data for Name: payment_gateway; Type: TABLE DATA; Schema: payment; Owner: postgres
--

INSERT INTO payment_gateway VALUES ('account_transfer', '');
INSERT INTO payment_gateway VALUES ('currency_conversion_transfer', '');
INSERT INTO payment_gateway VALUES ('gift_certificate', '');
INSERT INTO payment_gateway VALUES ('moneta', 'Moneta Payment Gateway');
INSERT INTO payment_gateway VALUES ('moneybookers', 'Moneybookers Payment Gateway');
INSERT INTO payment_gateway VALUES ('payment_agent_transfer', 'Payment Agent');
INSERT INTO payment_gateway VALUES ('legacy_payment', '');
INSERT INTO payment_gateway VALUES ('payment_fee', '');
INSERT INTO payment_gateway VALUES ('transactium_credit_debit_card', 'Transactium Payment Gateway');
INSERT INTO payment_gateway VALUES ('affiliate_reward', '');
INSERT INTO payment_gateway VALUES ('western_union', 'Western Union');
INSERT INTO payment_gateway VALUES ('envoy_transfer', '');
INSERT INTO payment_gateway VALUES ('bank_wire', '');
INSERT INTO payment_gateway VALUES ('datacash', 'Datacash Payment Gateway');
INSERT INTO payment_gateway VALUES ('pacnet', 'Local Cheque Pacnet');
INSERT INTO payment_gateway VALUES ('free_gift', 'free_gift for promotional code & other purpose');
INSERT INTO payment_gateway VALUES ('doughflow', 'DoughFlow Cashier System');


INSERT INTO payment_type VALUES ('internal_transfer', 'all transfers that are used internally to transfer money from one account in our system to another');
INSERT INTO payment_type VALUES ('cash_transfer', 'All cash transfer type of payments');
INSERT INTO payment_type VALUES ('credit_debit_card', 'All Credit and Debit Card payments');
INSERT INTO payment_type VALUES ('ewallet', 'Moneybookers and Moneta are ewallet type of payment also Webmoney,');
INSERT INTO payment_type VALUES ('payment_fee', '');
INSERT INTO payment_type VALUES ('affiliate_reward', '');
INSERT INTO payment_type VALUES ('bank_money_transfer', 'envoy_transfer and bank_wire are bank_money_transfer');
INSERT INTO payment_type VALUES ('local_cheque', '');
INSERT INTO payment_type VALUES ('free_gift', 'free_gift for promotional code & other purpose');
INSERT INTO payment_type VALUES ('closed_account', 'Account closed');
INSERT INTO payment_type VALUES ('cancellation', 'Cancel gifts');
INSERT INTO payment_type VALUES ('virtual_credit', 'Virtual money credit to new account');
INSERT INTO payment_type VALUES ('adjustment', 'credit or debit an amount to adjust the balance, for example: bet adjustment if settle bet wrongly previously');
INSERT INTO payment_type VALUES ('NPS', 'legacy payment system used for China client previously');
INSERT INTO payment_type VALUES ('bacs', 'bacs for withdrawal through Datacash');
INSERT INTO payment_type VALUES ('testing', 'testing for deposit or withdrawal');
INSERT INTO payment_type VALUES ('compacted_statement', 'compacted statement for client transaction file that has been compacted before');
INSERT INTO payment_type VALUES ('miscellaneous', 'for example, BOM Shop buy / sell');
INSERT INTO payment_type VALUES ('external_cashier', 'External Cashier System');
INSERT INTO payment_type VALUES ('dormant_fee', 'Dormant Fee');
INSERT INTO payment_type VALUES ('adjustment_purchase', 'Adjustment to Bet Purchase');
INSERT INTO payment_type VALUES ('adjustment_sale', 'Adjustment to Bet Sale');


INSERT INTO data_collection.exchange_rate(source_currency, target_currency, date, rate)
VALUES ('AUD', 'USD', '2008-01-01', 0.8755),
       ('CHF', 'USD', '2011-03-11', 0.9735),
       ('EUR', 'USD', '2002-05-01', 0.9368),
       ('GBP', 'USD', '2000-01-01', 1.4961),
       ('JPY', 'USD', '2008-04-01', 0.0096),
       ('USD', 'USD', '2000-01-01', 1.0000),
       ('XAD', 'USD', '2003-02-20', 1.0735);


GRANT USAGE ON SCHEMA accounting to read, write;
GRANT USAGE ON SCHEMA bet to read, write;
GRANT USAGE ON SCHEMA betonmarkets to read, write;
GRANT USAGE ON SCHEMA data_collection to read, write;
GRANT USAGE ON SCHEMA payment to read, write;
GRANT USAGE ON SCHEMA sequences to read, write;
GRANT USAGE ON SCHEMA transaction to read, write;


GRANT SELECT, UPDATE, INSERT, DELETE ON ALL TABLES IN SCHEMA accounting to read, write;
GRANT SELECT, UPDATE, INSERT, DELETE ON ALL TABLES IN SCHEMA betonmarkets to read, write;
GRANT SELECT, UPDATE, INSERT, DELETE ON ALL TABLES IN SCHEMA data_collection to read, write;
GRANT SELECT, UPDATE, INSERT ON ALL TABLES IN SCHEMA bet to read, write;
GRANT SELECT, UPDATE, INSERT ON ALL TABLES IN SCHEMA payment to read, write;
GRANT SELECT, UPDATE, INSERT ON ALL TABLES IN SCHEMA sequences to read, write;
GRANT SELECT, UPDATE, INSERT ON ALL TABLES IN SCHEMA transaction to read, write;


GRANT ALL ON ALL SEQUENCES IN SCHEMA sequences to write;


ALTER TABLE betonmarkets.client_lock ADD CONSTRAINT fk_client_loginid FOREIGN KEY (client_loginid) REFERENCES betonmarkets.client (loginid) MATCH FULL;
ALTER TABLE betonmarkets.client_promo_code ADD CONSTRAINT fk_promocode FOREIGN KEY (promotion_code) REFERENCES betonmarkets.promo_code (code) MATCH FULL;


REVOKE ALL ON transaction.account FROM read, write;
GRANT SELECT ON TABLE transaction.account TO  read, write;
GRANT INSERT (id, client_loginid, currency_code, is_default) ON TABLE transaction.account TO  read, write;
GRANT UPDATE (is_default) ON TABLE transaction.account TO  read, write;

REVOKE ALL ON transaction.transaction FROM read, write;
GRANT SELECT ON TABLE transaction.transaction TO  read, write;
GRANT INSERT (id, account_id, transaction_time, amount, staff_loginid, remark, referrer_type, financial_market_bet_id, payment_id, action_type, quantity) ON TABLE transaction.transaction TO  read, write;


COMMIT;
