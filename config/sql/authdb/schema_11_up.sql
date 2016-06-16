BEGIN;

CREATE TABLE oauth.ua_fingerprint (
    app_id           BIGINT NOT NULL REFERENCES oauth.apps(id),
    loginid          varchar(12) NOT NULL,
    ua_fingerprint   varchar(32)
);
ALTER TABLE ONLY oauth.ua_fingerprint
    ADD CONSTRAINT pkey_oauth_ua_fingerprint PRIMARY KEY (app_id, loginid);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.ua_fingerprint TO write;
GRANT SELECT ON oauth.ua_fingerprint TO read;

COMMIT;
