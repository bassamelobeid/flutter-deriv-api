BEGIN;

CREATE TYPE token_scopes AS ENUM ('read', 'trade', 'payments', 'admin');

DROP TABLE oauth.user_scope_confirm;
CREATE TABLE oauth.user_scope_confirm (
    app_id           varchar(32) NOT NULL REFERENCES oauth.apps(id),
    loginid          character varying(12) NOT NULL,
    scopes           token_scopes[]
);
ALTER TABLE ONLY oauth.user_scope_confirm
    ADD CONSTRAINT pkey_oauth_user_scope_confirm PRIMARY KEY (app_id, loginid);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.user_scope_confirm TO write;
GRANT SELECT ON oauth.user_scope_confirm TO read;

DROP TABLE oauth.auth_code_scope;
DROP TABLE oauth.auth_code;
CREATE TABLE oauth.auth_code (
    auth_code            char(32) NOT NULL PRIMARY KEY,
    app_id            varchar(32) NOT NULL REFERENCES oauth.apps(id),
    loginid              character varying(12) NOT NULL,
    expires              timestamp NOT NULL,
    scopes           token_scopes[],
    verified             boolean NOT NULL DEFAULT false
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.auth_code TO write;
GRANT SELECT ON oauth.auth_code TO read;

DROP TABLE oauth.access_token_scope;
DROP TABLE oauth.access_token;
CREATE TABLE oauth.access_token (
    access_token         char(32) NOT NULL PRIMARY KEY,
    app_id            varchar(32) NOT NULL REFERENCES oauth.apps(id),
    loginid              character varying(12) NOT NULL,
    expires              timestamp NOT NULL,
    scopes           token_scopes[],
    last_used            TIMESTAMP DEFAULT NULL
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.access_token TO write;
GRANT SELECT ON oauth.access_token TO read;

DROP TABLE oauth.refresh_token_scope;
DROP TABLE oauth.refresh_token;
CREATE TABLE oauth.refresh_token (
    refresh_token        char(32) NOT NULL PRIMARY KEY,
    app_id            varchar(32) NOT NULL REFERENCES oauth.apps(id),
    loginid              character varying(12) NOT NULL,
    scopes           token_scopes[],
    revoked BOOLEAN NOT NULL DEFAULT false
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.refresh_token TO write;
GRANT SELECT ON oauth.refresh_token TO read;

DROP TABLE oauth.scopes;

CREATE TABLE auth.scopes (
    id SERIAL PRIMARY KEY,
    scope VARCHAR( 100 ) NOT NULL
);
GRANT SELECT, INSERT, UPDATE, DELETE ON auth.scopes TO write;
GRANT SELECT ON auth.scopes TO read;

INSERT INTO auth.scopes (scope) VALUES ('read');
INSERT INTO auth.scopes (scope) VALUES ('trade');
INSERT INTO auth.scopes (scope) VALUES ('admin');
INSERT INTO auth.scopes (scope) VALUES ('payments');

CREATE TABLE auth.access_token_scope (
    access_token         char(16) NOT NULL,
    scope_id             INTEGER NOT NULL REFERENCES auth.scopes(id)
);
CREATE INDEX idx_auth_access_token_scope_access_token ON auth.access_token_scope USING btree (access_token);
GRANT SELECT, INSERT, UPDATE, DELETE ON auth.access_token_scope TO write;
GRANT SELECT ON auth.access_token_scope TO read;

COMMIT;