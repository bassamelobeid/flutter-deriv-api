SET client_min_messages TO warning;

BEGIN;
-- -------------------------------------

CREATE TABLE chronicle (
      id bigserial,
      timestamp TIMESTAMP DEFAULT NOW(),
      category VARCHAR(255),
      name VARCHAR(255),
      value TEXT,
      PRIMARY KEY(id),
      CONSTRAINT search_index UNIQUE(category,name,timestamp)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON chronicle TO write;
GRANT USAGE on chronicle_id_seq to write;
ALTER ROLE postgres WITH password 'picabo';

COMMIT;
