BEGIN;

ALTER TABLE oauth.apps ADD COLUMN redirect_uri VARCHAR(255);

UPDATE oauth.apps SET redirect_uri='https://www.binary.com/' WHERE id='binarycom';

DROP TABLE oauth.app_redirect_uri;

COMMIT;