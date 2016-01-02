BEGIN;

CREATE SCHEMA oauth;

CREATE TABLE oauth.clients (
    id varchar(36) NOT NULL PRIMARY KEY,
    secret varchar(36) NOT NULL,
    name VARCHAR(48) NOT NULL,
    binary_user_id BIGINT NOT NULL,
    active boolean NOT NULL DEFAULT true
);
insert into oauth.clients (id, client_secret, display_name, binary_user_id) values ('binarycom', 'bin2Sec', 'Binary.com', 1);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.clients TO write;
GRANT SELECT ON oauth.clients TO read;

CREATE TABLE oauth.auth_code (
    auth_code            varchar(36) NOT NULL PRIMARY KEY,
    client_id            varchar(36) NOT NULL REFERENCES oauth.clients(id),
    loginid              character varying(12) NOT NULL,
    expires              timestamp NOT NULL,
    verified             boolean NOT NULL DEFAULT false
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.auth_code TO write;
GRANT SELECT ON oauth.auth_code TO read;

CREATE TABLE oauth.access_token (
    access_token         varchar(255) NOT NULL PRIMARY KEY,
    client_id            varchar(36) NOT NULL REFERENCES oauth.clients(id),
    loginid              character varying(12) NOT NULL,
    expires              timestamp NOT NULL
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.access_token TO write;
GRANT SELECT ON oauth.access_token TO read;

CREATE TABLE oauth.refresh_token (
    refresh_token        varchar(255) NOT NULL PRIMARY KEY,
    client_id            varchar(36) NOT NULL REFERENCES oauth.clients(id),
    loginid              character varying(12) NOT NULL,
    revoked BOOLEAN NOT NULL DEFAULT false
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.refresh_token TO write;
GRANT SELECT ON oauth.refresh_token TO read;

COMMIT;