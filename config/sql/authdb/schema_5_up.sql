BEGIN;

ALTER TABLE oauth.apps ADD COLUMN redirect_uri VARCHAR(255);

UPDATE oauth.apps SET redirect_uri='/logged_inws' WHERE id='binarycom';

DROP TABLE oauth.app_redirect_uri;

COMMIT;