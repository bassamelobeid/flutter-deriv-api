BEGIN;

DROP TABLE auth.auth_codes CASCADE;
DROP TABLE auth.grants CASCADE;
DROP TABLE auth.users CASCADE;

COMMIT;
