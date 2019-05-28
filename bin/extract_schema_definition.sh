#!/bin/bash

# a bash script that takes in 3 params
# 1 - postfix of database repo bom-postgres-POSTFIX
# 2 - dbname
# 3 - dbport

if [ $# -ne 3 ]; then
	echo "Usage: $0 reponame dbname port"
	echo "example: $0 clientdb vr 5432"
	exit 1
fi

REPO_PATH=/home/git/regentmarkets/bom-postgres-$1

# generate schema for database
sudo -u postgres pg_dump --schema-only --quote-all-identifiers --dbname=$2 --port=$3 | \
	sed '/^--/d' | sed '/^\s*$/d' | \
	/home/git/regentmarkets/bom-postgres/bin/parse_schema --path $REPO_PATH --dbname $2 --port $3\
	&& git diff --color $REPO_PATH'/schema'  | cat

