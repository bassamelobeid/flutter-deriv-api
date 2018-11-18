#!/bin/bash
# install.sh - Travis setup for install phase
# See https://docs.travis-ci.com/user/job-lifecycle

set -ex

sudo ln -s "$PWD" /home/git/regentmarkets/bom-rpc
/tmp/travis-scripts/devbox.sh

/tmp/travis-scripts/remove_postgresdb_config.sh
/tmp/travis-scripts/setup_clientdb.sh
/tmp/travis-scripts/setup_feeddb.sh
/tmp/travis-scripts/setup_authdb.sh
/tmp/travis-scripts/setup_usersdb.sh
/tmp/travis-scripts/setup_chronicledb.sh

/tmp/travis-scripts/setup_postfix.sh
/tmp/travis-scripts/setup_logs.sh

/tmp/travis-scripts/postgres_service.sh
