#!/bin/bash
# install.sh - Travis setup for install phase
# See https://docs.travis-ci.com/user/job-lifecycle

set -ex

sudo ln -s "$PWD" /home/git/regentmarkets/binary-websocket-api
/tmp/travis-scripts/devbox.sh
sudo cp /etc/rmg/chronicle.yml /etc/rmg/ws-redis.yml

/tmp/travis-scripts/remove_postgresdb_config.sh
/tmp/travis-scripts/setup_clientdb.sh
/tmp/travis-scripts/setup_authdb.sh
/tmp/travis-scripts/setup_feeddb.sh
/tmp/travis-scripts/setup_usersdb.sh
/tmp/travis-scripts/setup_chronicledb.sh

/tmp/travis-scripts/setup_postfix.sh
/tmp/travis-scripts/setup_logs.sh
