BEGIN;

UPDATE oauth.apps SET name = 'Binary.com Expiry' WHERE id = 2;
UPDATE oauth.apps SET name = 'Binary.com Autosell' WHERE id = 3;

COMMIT;
