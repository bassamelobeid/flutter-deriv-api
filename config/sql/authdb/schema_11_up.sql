BEGIN;

ALTER TABLE oauth.apps ADD COLUMN markup_percentage NUMERIC DEFAULT 0;

COMMIT;
