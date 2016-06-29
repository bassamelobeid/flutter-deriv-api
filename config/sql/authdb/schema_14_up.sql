BEGIN;

ALTER TABLE oauth.apps SET name = 'Binary.com Expiry' WHERE id = 2;
ALTER TABLE oauth.apps SET name = 'Binary.com Autosell' WHERE id = 3;

COMMIT;
