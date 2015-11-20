SET client_min_messages TO warning;

BEGIN;
-- -------------------------------------

CREATE SCHEMA chronicle;

CREATE TABLE chronicle (
      id bigserial,
      timestamp TIMESTAMPTZ DEFAULT NOW(),
      category VARCHAR(255),
      name VARCHAR(255),
      value TEXT,
      PRIMARY KEY(id),
      CONSTRAINT search_index UNIQUE(category,name,timestamp)
);

GRANT USAGE ON SCHEMA chronicle TO read;
GRANT USAGE ON SCHEMA chronicle TO write;
GRANT USAGE ON SCHEMA chronicle TO monitor;
GRANT USAGE on chronicle_id_seq to write;

COMMIT;
