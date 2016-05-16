BEGIN;

-- rename field
ALTER TABLE oauth.apps RENAME COLUMN id TO key;
ALTER TABLE oauth.access_token RENAME COLUMN app_id TO app_key;
ALTER TABLE oauth.user_scope_confirm RENAME COLUMN app_id TO app_key;

-- drop fk
ALTER TABLE oauth.access_token DROP CONSTRAINT access_token_app_id_fkey;
ALTER TABLE oauth.user_scope_confirm DROP CONSTRAINT user_scope_confirm_app_id_fkey;

-- key unique
ALTER TABLE oauth.apps DROP CONSTRAINT apps_pkey;
ALTER TABLE oauth.apps ADD CONSTRAINT apps_key_unique UNIQUE (key);

-- fk
ALTER TABLE oauth.access_token ADD CONSTRAINT access_token_app_key_fkey FOREIGN KEY (app_key) REFERENCES oauth.apps (key);
ALTER TABLE oauth.user_scope_confirm ADD CONSTRAINT user_scope_confirm_app_key_fkey FOREIGN KEY (app_key) REFERENCES oauth.apps (key);

-- primary key
ALTER TABLE oauth.apps ADD COLUMN id SERIAL PRIMARY KEY;

GRANT USAGE ON oauth.apps_id_seq TO postgres;
GRANT USAGE ON oauth.apps_id_seq TO write;
GRANT USAGE ON oauth.apps_id_seq TO read;
ALTER SEQUENCE auth.apps_id_seq RESTART WITH 1000;

COMMIT;
