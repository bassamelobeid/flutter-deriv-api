BEGIN;

CREATE SERVER jp  FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'replica-jp',  dbname  'regentmarkets');

GRANT USAGE ON FOREIGN SERVER jp TO read, master_write, write;

CREATE USER MAPPING FOR postgres        SERVER jp  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR master_write    SERVER jp  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR write           SERVER jp  OPTIONS (user 'read', password 'letmein');
CREATE USER MAPPING FOR read            SERVER jp  OPTIONS (user 'read', password 'letmein');

COMMIT;
