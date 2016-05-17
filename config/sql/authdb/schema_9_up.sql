BEGIN;

-- TABLE: oauth.access_token, oauth.user_scope_confirm
-- drop FK
ALTER TABLE oauth.access_token          DROP CONSTRAINT access_token_app_id_fkey;
ALTER TABLE oauth.user_scope_confirm    DROP CONSTRAINT user_scope_confirm_app_id_fkey;
ALTER TABLE oauth.user_scope_confirm    DROP CONSTRAINT pkey_oauth_user_scope_confirm;

-- rename column
ALTER TABLE oauth.access_token          RENAME COLUMN app_id TO __app_id;
ALTER TABLE oauth.user_scope_confirm    RENAME COLUMN app_id TO __app_id;

-- new app_id column
ALTER TABLE oauth.access_token          ADD COLUMN app_id BIGINT;
ALTER TABLE oauth.user_scope_confirm    ADD COLUMN app_id BIGINT;


-- TABLE: oauth.apps
ALTER TABLE oauth.apps                  DROP CONSTRAINT apps_pkey;
ALTER TABLE oauth.apps                  RENAME COLUMN id TO __id;

-- new id field
CREATE SEQUENCE oauth.apps_id_seq
     START WITH 1000
     INCREMENT BY 1
     MINVALUE 1000
     NO MAXVALUE
     CACHE 1;
ALTER TABLE oauth.apps ADD COLUMN id BIGINT DEFAULT nextval('oauth.apps_id_seq'::regclass) NOT NULL PRIMARY KEY;

GRANT USAGE ON oauth.apps_id_seq TO postgres;
GRANT USAGE ON oauth.apps_id_seq TO write;
GRANT USAGE ON oauth.apps_id_seq TO read;

-- binarycom app
UPDATE oauth.apps                       SET id = 1 WHERE __id = 'binarycom';

-- populate app_id
UPDATE oauth.access_token               SET app_id = a.id FROM oauth.apps a WHERE __app_id = a.__id;
UPDATE oauth.user_scope_confirm         SET app_id = a.id FROM oauth.apps a WHERE __app_id = a.__id;

-- FK
ALTER TABLE oauth.access_token          ADD CONSTRAINT access_token_app_id_fkey         FOREIGN KEY (app_id) REFERENCES oauth.apps (id);
ALTER TABLE oauth.user_scope_confirm    ADD CONSTRAINT user_scope_confirm_app_id_fkey   FOREIGN KEY (app_id) REFERENCES oauth.apps (id);
ALTER TABLE oauth.user_scope_confirm    ADD PRIMARY KEY (app_id, loginid);

-- DROP old column
ALTER TABLE oauth.access_token          DROP COLUMN __app_id;
ALTER TABLE oauth.user_scope_confirm    DROP COLUMN __app_id;
ALTER TABLE oauth.apps                  DROP COLUMN __id;

COMMIT;
