-- This will create Database, schema & Roles for feed db
CREATE DATABASE feed;

CREATE ROLE read LOGIN PASSWORD 'letmein';
CREATE ROLE write LOGIN PASSWORD	'letmein';
CREATE ROLE monitor LOGIN PASSWORD	'letmein';
CREATE ROLE replicator LOGIN REPLICATION PASSWORD	'letmein';

