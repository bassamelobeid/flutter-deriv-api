BEGIN;

ALTER TABLE oauth.apps ADD COLUMN scopes token_scopes[];
UPDATE oauth.apps SET scopes='{"read","admin","trade","payments"}';

DROP TABLE oauth.auth_code;
DROP TABLE oauth.refresh_token;
ALTER TABLE oauth.access_token DROP COLUMN scopes;
ALTER TABLE oauth.user_scope_confirm DROP COLUMN scopes;

COMMIT;