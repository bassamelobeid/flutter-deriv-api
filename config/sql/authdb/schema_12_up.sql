BEGIN;

ALTER TABLE oauth.access_token ADD COLUMN ua_fingerprint VARCHAR(32);

COMMIT;
