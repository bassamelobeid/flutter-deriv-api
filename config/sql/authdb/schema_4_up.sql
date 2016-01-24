BEGIN;

CREATE SCHEMA oauth;
GRANT USAGE ON SCHEMA oauth TO read, write, monitor;

CREATE TABLE oauth.apps (
    id varchar(32) NOT NULL PRIMARY KEY,
    secret varchar(32) NOT NULL,
    name VARCHAR(48) NOT NULL,
    homepage VARCHAR(255) DEFAULT NULL,
    github VARCHAR(255) DEFAULT NULL,
    appstore VARCHAR(255) DEFAULT NULL,
    googleplay VARCHAR(255) DEFAULT NULL,
    binary_user_id BIGINT NOT NULL,
    active boolean NOT NULL DEFAULT true
);
CREATE INDEX idx_oauth_apps_binary_user_id ON oauth.apps USING btree (binary_user_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.apps TO write;
GRANT SELECT ON oauth.apps TO read;

INSERT INTO oauth.apps (id, secret, name, binary_user_id) values ('binarycom', 'bin2Sec', 'Binary.com', 1);

CREATE TABLE oauth.app_redirect_uri (
    app_id            varchar(32) NOT NULL REFERENCES oauth.apps(id),
    redirect_uri VARCHAR(255) DEFAULT NULL
);
CREATE INDEX idx_oauth_app_redirect_uri_app_id ON oauth.app_redirect_uri USING btree (app_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.app_redirect_uri TO write;
GRANT SELECT ON oauth.app_redirect_uri TO read;

INSERT INTO oauth.app_redirect_uri (app_id, redirect_uri) values ('binarycom', 'http://localhost/');
INSERT INTO oauth.app_redirect_uri (app_id, redirect_uri) values ('binarycom', 'https://www.binary.com/');

CREATE TABLE oauth.scopes (
    id SERIAL PRIMARY KEY,
    scope VARCHAR( 100 ) NOT NULL
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.scopes TO write;
GRANT SELECT ON oauth.scopes TO read;

INSERT INTO oauth.scopes (scope) VALUES ('user');
INSERT INTO oauth.scopes (scope) VALUES ('trade');
INSERT INTO oauth.scopes (scope) VALUES ('cashier');

CREATE TABLE oauth.user_scope_confirm (
    app_id            varchar(32) NOT NULL REFERENCES oauth.apps(id),
    loginid              character varying(12) NOT NULL,
    scope_id             INTEGER NOT NULL REFERENCES oauth.scopes(id)
);
ALTER TABLE ONLY oauth.user_scope_confirm
    ADD CONSTRAINT pkey_oauth_user_scope_confirm PRIMARY KEY (app_id, loginid, scope_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.user_scope_confirm TO write;
GRANT SELECT ON oauth.user_scope_confirm TO read;

CREATE TABLE oauth.auth_code (
    auth_code            char(32) NOT NULL PRIMARY KEY,
    app_id            varchar(32) NOT NULL REFERENCES oauth.apps(id),
    loginid              character varying(12) NOT NULL,
    expires              timestamp NOT NULL,
    verified             boolean NOT NULL DEFAULT false
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.auth_code TO write;
GRANT SELECT ON oauth.auth_code TO read;

CREATE TABLE oauth.auth_code_scope (
    auth_code            char(32) NOT NULL,
    scope_id             INTEGER NOT NULL REFERENCES oauth.scopes(id)
);
CREATE INDEX idx_oauth_auth_code_scope_auth_code ON oauth.auth_code_scope USING btree (auth_code);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.auth_code_scope TO write;
GRANT SELECT ON oauth.auth_code_scope TO read;

CREATE TABLE oauth.access_token (
    access_token         char(32) NOT NULL PRIMARY KEY,
    app_id            varchar(32) NOT NULL REFERENCES oauth.apps(id),
    loginid              character varying(12) NOT NULL,
    expires              timestamp NOT NULL,
    last_used            TIMESTAMP DEFAULT NULL
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.access_token TO write;
GRANT SELECT ON oauth.access_token TO read;

CREATE TABLE oauth.access_token_scope (
    access_token         char(32) NOT NULL,
    scope_id             INTEGER NOT NULL REFERENCES oauth.scopes(id)
);
CREATE INDEX idx_oauth_access_token_scope_access_token ON oauth.access_token_scope USING btree (access_token);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.access_token_scope TO write;
GRANT SELECT ON oauth.access_token_scope TO read;

CREATE TABLE oauth.refresh_token (
    refresh_token        char(32) NOT NULL PRIMARY KEY,
    app_id            varchar(32) NOT NULL REFERENCES oauth.apps(id),
    loginid              character varying(12) NOT NULL,
    revoked BOOLEAN NOT NULL DEFAULT false
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.refresh_token TO write;
GRANT SELECT ON oauth.refresh_token TO read;

CREATE TABLE oauth.refresh_token_scope (
    refresh_token        char(32) NOT NULL,
    scope_id             INTEGER NOT NULL REFERENCES oauth.scopes(id)
);
CREATE INDEX idx_oauth_refresh_token_scope_refresh_token ON oauth.refresh_token_scope USING btree (refresh_token);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.refresh_token_scope TO write;
GRANT SELECT ON oauth.refresh_token_scope TO read;

COMMIT;