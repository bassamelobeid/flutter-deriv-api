#!/bin/bash

set -e

usage () {
  cat <<EOF
Usage: $0 [service names, separated by whitespace]
Example: $0 [options] mf01 mlt01 ...

This script applies all DB functions to the target database(s) in a single
transaction. Options should be specified before the service names otherwise
they are considered as service names too.

Options:

  -h, --help:      Display this help message
  -d, --dry:       Dry run against the database (make sure to specify this
                   before any service name, otherwise it WILL NOT BE A DRY RUN)
  -r, --repo:      Repository to apply DB functions from (default: clientdb)
  -b, --branch:    Branch name or PR number to get the DB functions from
                   (default: master) (use '-' to skip the checkout step)
EOF
}

as_user() {
  user="$1" && shift
  sudo -Eu $user bash -o errexit $@
}

export DRY=
export BRANCH=master
export REPO=bom-postgres-clientdb
export ROOT=/home/git/regentmarkets
export PSQL="psql --single-transaction --no-psqlrc --set ON_ERROR_STOP=on"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 1;;
    -d|--dry) shift; DRY=1;;
    -r|--repo) shift; REPO=$1 && shift;;
    -b|--branch) shift; BRANCH=$1 && shift;;
    -*) usage; error "Invalid option $1";;
    *) break;;
  esac
done

export SERVICES="$@"
if [ -z "$SERVICES" ];then
  usage; exit 1;
fi

echo "Checking out to $BRANCH on $REPO"
as_user nobody <<'EOF'
  if [ "$BRANCH" == "-" ]; then
    echo 'Branch is set to -, skipping checkout'
    exit 0
  fi
  cd $ROOT/$REPO
  if ! git diff-index HEAD --quiet; then
    echo "$ROOT/$REPO is not clean, exiting..."
    exit 1
  fi
  if echo "$BRANCH" |grep -P '\d+'; then
    git fetch origin pull/$BRANCH/head:$BRANCH || git pull origin pull/$BRANCH/head:$BRANCH
  else
    git fetch origin --tags $BRANCH
  fi
  git checkout $BRANCH
  if [ "$BRANCH" == 'master' ]; then
    git reset --hard origin/master
  fi
  echo "Checked out to $BRANCH on $REPO"
EOF

echo "Applying DB functions to $SERVICES"
as_user pgadmin <<'EOF'
  cd $ROOT/$REPO
  if grep -rP 'BEGIN;|COMMIT|ROLLBACK' config/sql/functions/; then
    echo "detected transaction in function files, please remove BEGIN, COMMIT, ROLLBACK from your function files" && exit 1
  fi
  if grep -ri 'CREATE FUNCTION' config/sql/functions/; then
    echo "Detected CREATE FUNCTION, please replace that with CREATE OR REPLACE FUNCTION" && exit 1
  fi
  functions_to_apply=
  for fun in `git ls-tree -r --name-only HEAD config/sql/functions | sort -n`; do
    functions_to_apply+="\\i $fun;"$'\n'
  done
  for service in $SERVICES; do
    echo "Applying DB functions on $service"
    if [ -n "$DRY" ]; then
      echo "select 'Connected to \"$service\" successfully';" | $PSQL -At service="$service" && \
      echo -e "Would apply these functions:\n$functions_to_apply"
    else
      echo "$functions_to_apply" | $PSQL service="$service"
      echo "Applied DB functions on $service"
    fi
  done
  if [ -z "$DRY" ];then
    echo "Applied all DB functions on $SERVICES"
  fi
EOF
