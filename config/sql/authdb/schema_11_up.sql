BEGIN;

ALTER TABLE oauth.apps ADD COLUMN app_markup_percentage NUMERIC DEFAULT 0;

COMMIT;
