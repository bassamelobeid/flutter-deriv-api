#!/bin/bash

(pg_lsclusters | grep 5437 | grep main) && (pg_dropcluster --stop 9.4 main)
(pg_lsclusters | grep 5437) || (pg_createcluster -p 5437 --locale 'en_US.UTF-8' --start 9.4 chronicle)
grep '#listen_addresses' /etc/postgresql/9.4/chronicle/postgresql.conf && (sed -i "/#listen_addresses/c\listen_addresses = '*'" /etc/postgresql/9.4/chronicle/postgresql.conf; pg_ctlcluster 9.4 chronicle restart) || true

sudo -u postgres psql -p 5437 -v ON_ERROR_STOP=1 <<XXX
CREATE DATABASE chronicle
  ENCODING='UTF8'
  LC_COLLATE='en_US.UTF-8'
  LC_CTYPE='en_US.UTF-8';
CREATE ROLE write LOGIN password 'picabo';
CREATE ROLE replicator REPLICATION LOGIN PASSWORD 'picabo';
\c chronicle
CREATE TABLE chronicle (
  id bigserial,
  timestamp TIMESTAMPTZ DEFAULT NOW(),
  category VARCHAR(255),
  name VARCHAR(255),
  value TEXT,
  PRIMARY KEY(id),
  CONSTRAINT search_index UNIQUE(category,name,timestamp)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON chronicle TO write;
GRANT USAGE on chronicle_id_seq to write;
ALTER ROLE postgres WITH password 'picabo';
XXX

echo "setup_chronicle finished!"
