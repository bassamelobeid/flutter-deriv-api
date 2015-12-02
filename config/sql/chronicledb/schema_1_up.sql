SET client_min_messages TO warning;

BEGIN;
-- -------------------------------------

CREATE SCHEMA chronicle;

CREATE TABLE chronicle (
      id bigserial,
      timestamp TIMESTAMP DEFAULT NOW(),
      category VARCHAR(255),
      name VARCHAR(255),
      value TEXT,
      PRIMARY KEY(id),
      CONSTRAINT search_index UNIQUE(category,name,timestamp)
);

GRANT ALL ON SCHEMA chronicle TO write;

COMMIT;
