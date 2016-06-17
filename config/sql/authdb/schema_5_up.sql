BEGIN;

ALTER TABLE oauth.apps ADD COLUMN redirect_uri VARCHAR(255);

UPDATE oauth.apps SET redirect_uri='https://www.binary.com/en/logged_inws.html', homepage='', github='', appstore='', googleplay='' WHERE id='binarycom';

DROP TABLE oauth.app_redirect_uri;

COMMIT;
