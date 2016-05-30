BEGIN;

-- as scope is per app so need to create app with read only for backoffice
INSERT INTO oauth.apps (id, name, binary_user_id, redirect_uri, scopes) VALUES (4, 'Binary.com backoffice', 1, 'https://www.binary.com/en/logged_inws.html', '{read}');

COMMIT;
