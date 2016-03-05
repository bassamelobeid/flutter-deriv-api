BEGIN;

ALTER TABLE oauth.apps ADD COLUMN scopes token_scopes[];
UPDATE oauth.apps SET scopes='{"read","admin","trade","payments"}';

COMMIT;