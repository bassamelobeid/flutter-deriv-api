BEGIN;

CREATE SCHEMA auth;
GRANT CONNECT ON DATABASE auth to read, write;
GRANT USAGE ON SCHEMA auth TO read, write, monitor;


CREATE TABLE auth.developers (
	id SERIAL PRIMARY KEY,
	display_name VARCHAR(48) NOT NULL,
	description TEXT DEFAULT NULL,
	contact_name VARCHAR(48) NOT NULL,
	contact_email VARCHAR(48) NOT NULL UNIQUE,
	password VARCHAR(100) NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON auth.developers TO write;
GRANT SELECT ON auth.developers TO read;
GRANT USAGE ON auth.developers_id_seq TO write;
INSERT INTO auth.developers
	(id, display_name, description, contact_name, contact_email, password)
	VALUES (1, 'BetOnMarkets', 'BetOnMarkets', 'BetOnMarkets', 'support@betonmarkets.com', '42');
ALTER SEQUENCE auth.developers_id_seq RESTART WITH 1000;



CREATE TABLE auth.clients (
	id SERIAL PRIMARY KEY,
	client_secret VARCHAR(100) NOT NULL,
	display_name VARCHAR(48) NOT NULL,
	description TEXT NOT NULL,
	developer_id INTEGER NOT NULL REFERENCES auth.developers(id)
);
GRANT SELECT, INSERT, UPDATE ON auth.clients TO write;
GRANT SELECT ON auth.clients TO read;
GRANT USAGE ON auth.clients_id_seq TO write;
INSERT INTO auth.clients
	(id, client_secret, display_name, description, developer_id)
	VALUES (1, '42', 'BetOnMarkets website', 'BetOnMarkets website', 1);
ALTER SEQUENCE auth.clients_id_seq RESTART WITH 1000;



CREATE TABLE auth.users (
	id SERIAL PRIMARY KEY,
	login VARCHAR(12) NOT NULL UNIQUE
);
GRANT SELECT, INSERT ON auth.users TO write;
GRANT SELECT ON auth.users TO read;
GRANT USAGE ON auth.users_id_seq TO write;



CREATE TABLE auth.grants (
	id SERIAL PRIMARY KEY,
	user_id INTEGER REFERENCES auth.users(id),
	client_id INTEGER REFERENCES auth.clients(id),
	token VARCHAR(27) UNIQUE DEFAULT NULL,
	expires TIMESTAMP NOT NULL,
        scopes VARCHAR(256) DEFAULT NULL
);
GRANT SELECT, INSERT, UPDATE ON auth.grants TO write;
GRANT SELECT ON auth.grants TO read;
GRANT USAGE ON auth.grants_id_seq TO write;

CREATE TABLE auth.auth_codes (
	auth_code VARCHAR(16) PRIMARY KEY,
	expires TIMESTAMP NOT NULL,
	grant_id INTEGER NOT NULL REFERENCES auth.grants(id),
	used BOOLEAN DEFAULT FALSE
);
GRANT SELECT, INSERT, UPDATE ON auth.auth_codes TO write;
GRANT SELECT ON auth.auth_codes TO write;
GRANT SELECT ON auth.auth_codes TO read;

-- this is for Zenoss monitoring
GRANT SELECT ON ALL TABLES IN SCHEMA auth TO monitor;

-- This is safe to run multiple times.  Impersonating logins haven't matched
-- for some time.  It just adds the new scopes needed to change passwords or
-- access cashier.

UPDATE auth.grants SET scopes = '["chart","price","trade","password","cashier"]'
 WHERE scopes = '["chart","price","trade"]' and expires > now();

COMMIT;
