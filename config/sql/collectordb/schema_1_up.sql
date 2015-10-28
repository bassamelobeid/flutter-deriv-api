BEGIN;

CREATE SCHEMA IF NOT EXISTS betonmarkets;
GRANT USAGE ON SCHEMA betonmarkets TO general_write, client_read, client_write;

CREATE SCHEMA IF NOT EXISTS data_collection;
GRANT USAGE ON SCHEMA data_collection TO general_write, client_read, client_write;

CREATE SCHEMA IF NOT EXISTS accounting;
GRANT USAGE ON SCHEMA accounting TO general_write, client_read, client_write;

CREATE SCHEMA IF NOT EXISTS sequences;
GRANT USAGE ON SCHEMA sequences TO general_write, client_read, client_write;


-- CREATE sequences.global_serial IF NOT EXISTS
CREATE OR REPLACE FUNCTION create_global_sequence_if_not_exists() RETURNS VOID AS $$
DECLARE
    schema_name VARCHAR;
BEGIN
    SELECT relname INTO schema_name FROM pg_class WHERE relkind = 'S' AND oid::regclass::text = 'sequences.global_serial';
    IF schema_name IS NULL THEN
        CREATE SEQUENCE sequences.global_serial START WITH 200007 INCREMENT BY 20 MINVALUE 200007;
    END IF;
END;
$$ LANGUAGE plpgsql;

SELECT create_global_sequence_if_not_exists();


CREATE TABLE IF NOT EXISTS betonmarkets.promo_code(
    code VARCHAR (20) NOT NULL,
    start_date TIMESTAMP(0),
    expiry_date TIMESTAMP(0),
    status BOOL NOT NULL DEFAULT TRUE,
    promo_code_type VARCHAR (100) NOT NULL,
    promo_code_config TEXT NOT NULL,
    description VARCHAR (255) NOT NULL,
    CONSTRAINT PK_promo_code PRIMARY KEY (code),
    CONSTRAINT check_promo_code_code_format CHECK (code ~ E'^[a-zA-Z0-9_\\-.]+$')
);
GRANT SELECT ON betonmarkets.promo_code TO client_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON betonmarkets.promo_code TO general_write, client_write;


CREATE TABLE IF NOT EXISTS data_collection.exchange_rate (
    id BIGINT DEFAULT nextval('sequences.global_serial') NOT NULL,
    source_currency CHARACTER(3) NOT NULL,
    target_currency CHARACTER(3) NOT NULL,
    date TIMESTAMP WITHOUT TIME ZONE,
    rate NUMERIC(10,4),
    CONSTRAINT PK_exchange_rate PRIMARY KEY (id),
    UNIQUE (source_currency, target_currency, date)
);
GRANT SELECT ON data_collection.exchange_rate TO client_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON data_collection.exchange_rate TO general_write, client_write;


CREATE TABLE IF NOT EXISTS  data_collection.myaffiliates_token_details (
    token TEXT PRIMARY KEY NOT NULL,
    user_id BIGINT,
    username TEXT,
    status TEXT,
    email TEXT,
    tags TEXT
) WITH OIDS;
GRANT SELECT ON data_collection.myaffiliates_token_details TO client_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON data_collection.myaffiliates_token_details TO general_write, client_write;


CREATE TABLE IF NOT EXISTS  data_collection.myaffiliates_commission (
    id BIGINT DEFAULT nextval('sequences.global_serial') NOT NULL PRIMARY KEY,
    affiliate_userid BIGINT,
    affiliate_username TEXT,
    effective_date DATE,
    intraday_turnover NUMERIC(20,2),
    runbet_turnover NUMERIC(20,2),
    other_turnover NUMERIC(20,2),
    pnl NUMERIC(20,2),
    effective_pnl_for_commission NUMERIC(20,2),
    carry_over_to_next_month NUMERIC(20,2),
    commission NUMERIC(20,2),
    CONSTRAINT UK_userid_username_date UNIQUE (affiliate_userid, affiliate_username, effective_date)
);
GRANT SELECT ON data_collection.myaffiliates_commission TO client_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON data_collection.myaffiliates_commission TO general_write, client_write;


-- Hold the client balance as of the EOD on the effective date
CREATE TABLE IF NOT EXISTS accounting.end_of_day_balances(
    id BIGINT DEFAULT nextval('sequences.global_serial') NOT NULL PRIMARY KEY,
    account_id BIGINT NOT NULL,
    effective_date TIMESTAMP(0) NOT NULL,
    balance NUMERIC(14,4) NOT NULL,
    CONSTRAINT eod_balance_acct_date_uk UNIQUE (account_id, effective_date)
);
GRANT SELECT ON accounting.end_of_day_balances TO client_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON accounting.end_of_day_balances TO general_write, client_write;


-- Hold the client open positions as of the EOD on the effective date
CREATE TABLE IF NOT EXISTS accounting.end_of_day_open_positions(
    id BIGINT DEFAULT nextval('sequences.global_serial') NOT NULL PRIMARY KEY,
    end_of_day_balance_id INTEGER NOT NULL,
    financial_market_bet_id BIGINT NOT NULL,
    marked_to_market_value NUMERIC(9,4),
    CONSTRAINT eod_open_pos_balance_fk FOREIGN KEY (end_of_day_balance_id) REFERENCES accounting.end_of_day_balances(id) ON DELETE CASCADE
);
GRANT SELECT ON accounting.end_of_day_open_positions TO client_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON accounting.end_of_day_open_positions TO general_write, client_write;


CREATE TABLE IF NOT EXISTS accounting.realtime_book (
    id BIGINT DEFAULT nextval('sequences.global_serial') NOT NULL PRIMARY KEY,
    financial_market_bet_id BIGINT,
    market_price NUMERIC(10,4),
    delta NUMERIC,
    theta NUMERIC,
    vega NUMERIC,
    gamma NUMERIC
);
GRANT SELECT ON accounting.realtime_book TO client_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON accounting.realtime_book TO general_write, client_write;


CREATE TABLE IF NOT EXISTS accounting.historical_marked_to_market (
    id BIGINT DEFAULT nextval('sequences.global_serial') NOT NULL PRIMARY KEY,
    calculation_time TIMESTAMP,
    market_value NUMERIC(10,4),
    delta NUMERIC,
    theta NUMERIC,
    vega NUMERIC,
    gamma NUMERIC
);
GRANT SELECT ON accounting.historical_marked_to_market TO client_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON accounting.historical_marked_to_market TO general_write, client_write;


CREATE TABLE IF NOT EXISTS accounting.realtime_book_archive (
    id BIGINT NOT NULL PRIMARY KEY,
    calculation_time TIMESTAMP DEFAULT NOW(),
    financial_market_bet_id BIGINT,
    market_price numeric(10,4),
    delta numeric,
    theta numeric,
    vega numeric,
    gamma numeric
);
GRANT SELECT ON accounting.realtime_book_archive TO client_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON accounting.realtime_book_archive TO general_write, client_write;


CREATE TABLE IF NOT EXISTS accounting.expired_unsold (
    id BIGINT DEFAULT nextval('sequences.global_serial') NOT NULL PRIMARY KEY,
    financial_market_bet_id BIGINT,
    market_price numeric(10,4)
);
GRANT SELECT ON accounting.expired_unsold TO client_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON accounting.expired_unsold TO general_write, client_write;

CREATE OR REPLACE FUNCTION accounting.archive_realtime_book()
RETURNS TRIGGER AS $archive_realtime_book$
    BEGIN
        IF (TG_OP = 'INSERT') THEN
            INSERT INTO accounting.realtime_book_archive
                (financial_market_bet_id, market_price, delta,theta,vega,gamma, id)  VALUES
                (NEW.financial_market_bet_id, NEW.market_price, NEW.delta,NEW.theta,NEW.vega,NEW.gamma, NEW.id);
        END IF;
        RETURN NEW;
    END;
$archive_realtime_book$ SECURITY DEFINER LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS archive_realtime_book ON accounting.realtime_book;
CREATE TRIGGER archive_realtime_book BEFORE INSERT ON accounting.realtime_book FOR EACH ROW EXECUTE PROCEDURE  accounting.archive_realtime_book();

DROP INDEX IF EXISTS accounting.financial_market_bet_id_idx;
CREATE INDEX financial_market_bet_id_idx ON accounting.realtime_book_archive (financial_market_bet_id);

DROP INDEX IF EXISTS accounting.calculation_time_idx;
CREATE INDEX calculation_time_idx ON accounting.realtime_book_archive (calculation_time);

DROP INDEX IF EXISTS accounting.historical_mtm_calculation_time_desc_idx;
CREATE INDEX historical_mtm_calculation_time_desc_idx ON accounting.historical_marked_to_market (calculation_time);

CREATE TABLE data_collection.underlying_symbol_currency_mapper (
    id BIGSERIAL PRIMARY KEY,
    symbol TEXT NOT NULL,
    market TEXT NOT NULL,
    submarket TEXT NOT NULL,
    quoted_currency TEXT
);
GRANT SELECT ON TABLE data_collection.underlying_symbol_currency_mapper TO client_read;
GRANT SELECT, UPDATE, INSERT ON TABLE data_collection.underlying_symbol_currency_mapper
      TO client_write, general_write;
GRANT USAGE, SELECT, UPDATE ON SEQUENCE data_collection.underlying_symbol_currency_mapper_id_seq
      TO client_write, general_write;

INSERT INTO data_collection.underlying_symbol_currency_mapper ( symbol, market, submarket, quoted_currency) VALUES
    ( 'frxIEPUSD', 'forex', 'minor', 'USD' ),
    ( 'ranJD24', 'random', 'random_index', 'USD' ),
    ( 'ranJU24', 'random', 'random_index', 'USD' ),
    ( 'SPGTTF', 'sectors', 'global', 'USD' ),
    ( 'TSE', 'indices', 'asia_oceania', 'JPY' ),
    ( 'UK_AAL', 'stocks', 'uk', 'GBP' ),
    ( 'UK_ANL', 'stocks', 'uk', 'GBP' ),
    ( 'UK_AV', 'stocks', 'uk', 'GBP' ),
    ( 'UK_AZN', 'stocks', 'uk', 'GBP' ),
    ( 'UK_BA', 'stocks', 'uk', 'GBP' ),
    ( 'UK_BARC', 'stocks', 'uk', 'GBP' ),
    ( 'UK_BATS', 'stocks', 'uk', 'GBP' ),
    ( 'UK_BAY', 'stocks', 'uk', 'GBP' ),
    ( 'UK_BP', 'stocks', 'uk', 'GBP' ),
    ( 'UK_BSY', 'stocks', 'uk', 'GBP' ),
    ( 'UK_BT', 'stocks', 'uk', 'GBP' ),
    ( 'UK_CNA', 'stocks', 'uk', 'GBP' ),
    ( 'UK_CW', 'stocks', 'uk', 'GBP' ),
    ( 'UK_GSK', 'stocks', 'uk', 'GBP' ),
    ( 'UK_HBOS', 'stocks', 'uk', 'GBP' ),
    ( 'UK_HSBA', 'stocks', 'uk', 'GBP' ),
    ( 'UK_LGEN', 'stocks', 'uk', 'GBP' ),
    ( 'UK_LLOY', 'stocks', 'uk', 'GBP' ),
    ( 'UK_MKS', 'stocks', 'uk', 'GBP' ),
    ( 'UK_NRK', 'stocks', 'uk', 'GBP' ),
    ( 'UK_OOM', 'stocks', 'uk', 'GBP' ),
    ( 'UK_PRU', 'stocks', 'uk', 'GBP' ),
    ( 'UK_RBS', 'stocks', 'uk', 'GBP' ),
    ( 'UK_RDSA', 'stocks', 'uk', 'GBP' ),
    ( 'UK_RIO', 'stocks', 'uk', 'GBP' ),
    ( 'UK_RR', 'stocks', 'uk', 'GBP' ),
    ( 'UK_RSA', 'stocks', 'uk', 'GBP' ),
    ( 'UK_SMIN', 'stocks', 'uk', 'GBP' ),
    ( 'UK_TSCO', 'stocks', 'uk', 'GBP' ),
    ( 'UK_VOD', 'stocks', 'uk', 'GBP' ),
    ( 'UK_XTA', 'stocks', 'uk', 'GBP' ),
    ( 'USAAAPL', 'stocks', 'us', 'USD' ),
    ( 'USAADBE', 'stocks', 'us', 'USD' ),
    ( 'USAALTR', 'stocks', 'us', 'USD' ),
    ( 'USAAMAT', 'stocks', 'us', 'USD' ),
    ( 'USAAMGN', 'stocks', 'us', 'USD' ),
    ( 'USABEAS', 'stocks', 'us', 'USD' ),
    ( 'USABRCD', 'stocks', 'us', 'USD' ),
    ( 'USABRCDE', 'stocks', 'us', 'USD' ),
    ( 'USABRCM', 'stocks', 'us', 'USD' ),
    ( 'USACHKP', 'stocks', 'us', 'USD' ),
    ( 'USACIEN', 'stocks', 'us', 'USD' ),
    ( 'USACMVT', 'stocks', 'us', 'USD' ),
    ( 'USACSCO', 'stocks', 'us', 'USD' ),
    ( 'USADELL', 'stocks', 'us', 'USD' ),
    ( 'USAEBAY', 'stocks', 'us', 'USD' ),
    ( 'USAFLEX', 'stocks', 'us', 'USD' ),
    ( 'USAGOOG', 'stocks', 'us', 'USD' ),
    ( 'USAIMNX', 'stocks', 'us', 'USD' ),
    ( 'USAINTC', 'stocks', 'us', 'USD' ),
    ( 'USAINTU', 'stocks', 'us', 'USD' ),
    ( 'USAJDSU', 'stocks', 'us', 'USD' ),
    ( 'USAJNPR', 'stocks', 'us', 'USD' ),
    ( 'USAKLAC', 'stocks', 'us', 'USD' ),
    ( 'USALLTC', 'stocks', 'us', 'USD' ),
    ( 'USAMSFT', 'stocks', 'us', 'USD' ),
    ( 'USANVDA', 'stocks', 'us', 'USD' ),
    ( 'USAORCL', 'stocks', 'us', 'USD' ),
    ( 'USAPSFT', 'stocks', 'us', 'USD' ),
    ( 'USAQCOM', 'stocks', 'us', 'USD' ),
    ( 'USAQQQ', 'stocks', 'us', 'USD' ),
    ( 'USAQQQQ', 'stocks', 'us', 'USD' ),
    ( 'USASEBL', 'stocks', 'us', 'USD' ),
    ( 'USASUNW', 'stocks', 'us', 'USD' ),
    ( 'USAVRSN', 'stocks', 'us', 'USD' ),
    ( 'USAVRTS', 'stocks', 'us', 'USD' ),
    ( 'USAXLNX', 'stocks', 'us', 'USD' );

CREATE EXTENSION IF NOT EXISTS postgres_fdw WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA public;

CREATE SERVER cr  FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'replica-cr',  dbname  'regentmarkets');
CREATE SERVER mx  FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'replica-mx',  dbname  'regentmarkets');
CREATE SERVER mlt FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'replica-mlt', dbname  'regentmarkets');
CREATE SERVER vr  FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'replica-vr',  dbname  'regentmarkets');
CREATE SERVER mf  FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'replica-mf',  dbname  'regentmarkets');

CREATE USER MAPPING FOR postgres SERVER cr  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR postgres SERVER mx  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR postgres SERVER mlt OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR postgres SERVER vr  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR postgres SERVER mf  OPTIONS (user 'read', password 'letmein');

GRANT USAGE ON FOREIGN SERVER cr TO read, master_write, write;
GRANT USAGE ON FOREIGN SERVER mx TO read, master_write, write;
GRANT USAGE ON FOREIGN SERVER mlt TO read, master_write, write;
GRANT USAGE ON FOREIGN SERVER vr TO read, master_write, write;
GRANT USAGE ON FOREIGN SERVER mf TO read, master_write, write;

CREATE USER MAPPING FOR master_write SERVER cr  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR master_write SERVER mx  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR master_write SERVER mlt OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR master_write SERVER vr  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR master_write SERVER mf  OPTIONS (user 'read', password 'letmein');

CREATE USER MAPPING FOR write SERVER cr  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR write SERVER mx  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR write SERVER mlt OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR write SERVER vr  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR write SERVER mf  OPTIONS (user 'read', password 'letmein');

CREATE USER MAPPING FOR read SERVER cr  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR read SERVER mx  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR read SERVER mlt OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR read SERVER vr  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR read SERVER mf  OPTIONS (user 'read', password 'letmein');

COMMIT;
