BEGIN;

UPDATE oauth.apps SET redirect_uri='https://www.binary.com/en/logged_inws.html' WHERE id IN (2, 3);

COMMIT;
