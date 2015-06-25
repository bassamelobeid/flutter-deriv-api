--
-- PostgreSQL database cluster dump
--

\connect postgres

SET client_encoding = 'UTF8';
SET standard_conforming_strings = off;
SET escape_string_warning = 'off';
SET log_error_verbosity = 'TERSE';
--
-- Roles
--

CREATE ROLE client_read;
ALTER ROLE client_read WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN CONNECTION LIMIT 300;
CREATE ROLE maintainer;
ALTER ROLE maintainer WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN CONNECTION LIMIT 300;
CREATE ROLE client_write;
ALTER ROLE client_write WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN CONNECTION LIMIT 300;
CREATE ROLE delete_on_betonmarkets;
ALTER ROLE delete_on_betonmarkets WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN;
CREATE ROLE delete_on_betonmarkets_limited;
ALTER ROLE delete_on_betonmarkets_limited WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN;
CREATE ROLE general_write;
ALTER ROLE general_write WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN CONNECTION LIMIT 300;
CREATE ROLE insert_on_betonmarkets;
ALTER ROLE insert_on_betonmarkets WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN;
CREATE ROLE master_write;
ALTER ROLE master_write WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN PASSWORD 'md500d4baf36501f936639a0bc3210308ce';
CREATE ROLE monitor;
ALTER ROLE monitor WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN PASSWORD 'md59b15a21e3ee8db4e60ff34828aa0f103';
CREATE ROLE monitoring;
ALTER ROLE monitoring WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN CONNECTION LIMIT 10;
CREATE ROLE read;
ALTER ROLE read WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN PASSWORD 'md544336e83ed75c60eba996b461a678f10';
CREATE ROLE recover;
ALTER ROLE recover WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN PASSWORD 'md54c689c1385b68cb1ec2b3962d039b577';
CREATE ROLE recovery;
ALTER ROLE recovery WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN CONNECTION LIMIT 300;
CREATE ROLE remote_log;
ALTER ROLE remote_log WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN PASSWORD 'md58689f28668e846b9b1d918bf8ea42586';
CREATE ROLE remote_server_log;
ALTER ROLE remote_server_log WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN CONNECTION LIMIT 300;
CREATE ROLE replicator;
ALTER ROLE replicator WITH SUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN PASSWORD 'md539d84e175dad7092bf195722a989c4bf';
CREATE ROLE select_on_audit;
ALTER ROLE select_on_audit WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN;
CREATE ROLE select_on_betonmarkets;
ALTER ROLE select_on_betonmarkets WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN;
CREATE ROLE update_on_betonmarkets;
ALTER ROLE update_on_betonmarkets WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN;
CREATE ROLE write;
ALTER ROLE write WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN PASSWORD 'md5e3a1b747c630f1bea251e631975f9472';


--
-- Role memberships
--

GRANT client_read TO read GRANTED BY postgres;
GRANT client_write TO master_write GRANTED BY postgres;
GRANT client_write TO write GRANTED BY postgres;
GRANT delete_on_betonmarkets TO recovery GRANTED BY postgres;
GRANT delete_on_betonmarkets_limited TO client_write GRANTED BY postgres;
GRANT general_write TO master_write GRANTED BY postgres;
GRANT insert_on_betonmarkets TO client_write GRANTED BY postgres;
GRANT insert_on_betonmarkets TO recovery GRANTED BY postgres;
GRANT monitoring TO monitor GRANTED BY postgres;
GRANT recovery TO recover GRANTED BY postgres;
GRANT remote_server_log TO remote_log GRANTED BY postgres;
GRANT select_on_audit TO monitoring GRANTED BY postgres;
GRANT select_on_audit TO recovery GRANTED BY postgres;
GRANT select_on_betonmarkets TO client_read GRANTED BY postgres;
GRANT select_on_betonmarkets TO client_write GRANTED BY postgres;
GRANT select_on_betonmarkets TO general_write GRANTED BY postgres;
GRANT select_on_betonmarkets TO monitoring GRANTED BY postgres;
GRANT select_on_betonmarkets TO recovery GRANTED BY postgres;
GRANT select_on_betonmarkets TO remote_server_log GRANTED BY postgres;
GRANT update_on_betonmarkets TO client_write GRANTED BY postgres;
GRANT update_on_betonmarkets TO recovery GRANTED BY postgres;




--
-- PostgreSQL database cluster dump complete
--


