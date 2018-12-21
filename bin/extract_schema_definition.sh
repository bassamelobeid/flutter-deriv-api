#!/bin/bash

if [ $# -ne 2 ]; then
	echo "Usage: $0 database service"
	echo "example: $0 clientdb vr01"
	exit 1
fi

REPO_PATH_BASE=/home/git/regentmarkets/bom-postgres-

PORT=5432
DB_NAME=regentmarkets
REPO_PATH=$REPO_PATH_BASE'clientdb'

case $1 in 
	clientdb ) ;;
	userdb )
		PORT=5436
		DB_NAME=users
		REPO_PATH=$REPO_PATH_BASE'userdb'
	;;
	authdb )
		PORT=5435
		DB_NAME=auth
		REPO_PATH=$REPO_PATH_BASE'authdb'
	;;
	* )
		echo "Unknown database name: $1"
		exit 1
	;;
esac

SERVICE=$2

sudo -u pgadmin pg_dump --schema-only --quote-all-identifiers -p $PORT $DB_NAME | \
	sed '/^--/d' | sed '/^\s*$/d' | \
	/home/git/regentmarkets/bom-postgres/bin/parse_schema --path $REPO_PATH --service $SERVICE \
	&& git diff --color $REPO_PATH'/schema'  | cat
