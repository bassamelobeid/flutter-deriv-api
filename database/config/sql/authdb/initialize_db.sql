CREATE DATABASE auth
	ENCODING='UTF8'
	LC_COLLATE='en_US.UTF-8'
	LC_CTYPE='en_US.UTF-8';
CREATE ROLE read  LOGIN password 'letmein';
CREATE ROLE write LOGIN password 'letmein';
CREATE ROLE monitor LOGIN PASSWORD 'letmein';
CREATE ROLE replicator REPLICATION LOGIN PASSWORD 'letmein';
