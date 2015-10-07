BEGIN;

CREATE TABLE auth.access_token (
    token CHAR(12) NOT NULL PRIMARY KEY,
    display_name VARCHAR(64) NOT NULL,
    client_loginid character varying(12) NOT NULL,
    last_used timestamp DEFAULT NULL
);
CREATE INDEX idx_access_token_client_loginid ON auth.access_token USING btree (client_loginid);
GRANT SELECT, INSERT, UPDATE, DELETE ON auth.access_token TO write;
GRANT SELECT ON auth.access_token TO read;

COMMIT;
