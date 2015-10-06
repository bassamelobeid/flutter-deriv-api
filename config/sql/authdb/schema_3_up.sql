BEGIN;

CREATE TABLE auth.access_token (
    id SERIAL PRIMARY KEY,
    token CHAR(8) NOT NULL UNIQUE,
    display_name VARCHAR(48) NOT NULL,
    client_loginid character varying(12) NOT NULL,
    last_used timestamp DEFAULT NULL
);
CREATE INDEX idx_access_token_client_loginid ON auth.access_token USING btree (client_loginid);
GRANT SELECT, INSERT, UPDATE, DELETE ON auth.access_token TO write;
GRANT SELECT ON auth.access_token TO read;
GRANT USAGE ON auth.access_token_id_seq TO write;

COMMIT;
