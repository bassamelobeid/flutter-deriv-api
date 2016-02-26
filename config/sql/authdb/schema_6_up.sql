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
    auth_code            varchar(32) NOT NULL PRIMARY KEY,
    app_id               varchar(32) NOT NULL REFERENCES oauth.apps(id),
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
    access_token         varchar(32) NOT NULL PRIMARY KEY,
    app_id               varchar(32) NOT NULL REFERENCES oauth.apps(id),
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
    refresh_token        varchar(32) NOT NULL PRIMARY KEY,
    app_id               varchar(32) NOT NULL REFERENCES oauth.apps(id),
    loginid              character varying(12) NOT NULL,
    scopes           token_scopes[],
    revoked BOOLEAN NOT NULL DEFAULT false
);
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth.refresh_token TO write;
GRANT SELECT ON oauth.refresh_token TO read;

DROP TABLE oauth.scopes;

ALTER TABLE auth.access_token ADD COLUMN scopes token_scopes[];
UPDATE auth.access_token SET scopes='{"read","admin","trade","payments"}';


CREATE OR REPLACE FUNCTION auth.create_token(p_tlen        INT,
                                             p_loginid     TEXT,
                                             p_displayname TEXT,
                                             p_scopes      token_scopes[])
RETURNS TEXT AS $$

DECLARE
    t TEXT;
BEGIN
    LOOP
        BEGIN
            -- An INSERT locks the table automatically in ROW EXCLUSIVE mode
            -- which blocks concurrent modifications. Hence, no other locking
            -- is required.
            INSERT INTO auth.access_token(token, display_name, client_loginid, scopes)
            VALUES (auth.generate_random_token(p_tlen),
                    p_displayname, p_loginid, p_scopes)
            RETURNING token INTO t;
            RETURN t;
        EXCEPTION WHEN unique_violation THEN
            -- do nothing and continue with next loop
        END;
    END LOOP;
END;

$$ LANGUAGE plpgsql VOLATILE;

COMMIT;