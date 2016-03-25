BEGIN;

ALTER TABLE oauth.access_token ADD COLUMN creation_time timestamp NOT NULL DEFAULT now();
UPDATE oauth.access_token SET creation_time = expires - INTERVAL '1 day';

COMMIT;
