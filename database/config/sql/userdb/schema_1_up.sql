BEGIN;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS users;
GRANT CONNECT ON DATABASE users to read, write;
GRANT USAGE ON SCHEMA users TO read, write, monitor;

SET search_path = users;

CREATE TABLE IF NOT EXISTS binary_user (
    id BIGSERIAL NOT NULL PRIMARY KEY,
    email VARCHAR(100) NOT NULL UNIQUE,
    password VARCHAR(100) NOT NULL,
    email_verified boolean DEFAULT false NOT NULL
);
GRANT SELECT, INSERT, UPDATE, DELETE ON users.binary_user TO write;
GRANT SELECT ON users.binary_user TO read;
GRANT USAGE ON users.binary_user_id_seq TO write;

CREATE TABLE IF NOT EXISTS loginid (
    loginid VARCHAR(12) NOT NULL PRIMARY KEY,
    binary_user_id BIGINT NOT NULL,
    CONSTRAINT fk_user FOREIGN KEY (binary_user_id) REFERENCES binary_user(id) ON UPDATE CASCADE ON DELETE RESTRICT
);
GRANT SELECT, INSERT, UPDATE ON users.loginid TO write;
GRANT SELECT ON users.loginid TO read;

-- temporary table for the moment of migration. It indicates from which loginid the password if from in binary_user table
CREATE TABLE IF NOT EXISTS email_password_map (
    email VARCHAR(100) NOT NULL PRIMARY KEY,
    password_from VARCHAR(12) NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON users.email_password_map TO write;
GRANT SELECT ON users.email_password_map TO read;

COMMIT;
