#!/bin/bash
# before_install.sh - Travis setup for before_install phase
# See https://docs.travis-ci.com/user/job-lifecycle

set -ex

git clone ssh://git@github.com/regentmarkets/travis-scripts /tmp/travis-scripts-init
/tmp/travis-scripts-init/clone_branch.sh regentmarkets/travis-scripts
/tmp/travis-scripts/setup_ssh.sh

sudo mkdir -p /home/git/binary-com /home/git/regentmarkets /etc/rmg

. /tmp/travis-scripts/setup_perl.sh

/tmp/travis-scripts/fixHostName.sh

/tmp/travis-scripts/parallel_clone_branch.sh \
    regentmarkets/bom-test \
    regentmarkets/bom \
    regentmarkets/bom-config \
    regentmarkets/bom-platform \
    regentmarkets/bom-user \
    regentmarkets/bom-feed \
    regentmarkets/bom-populator \
    regentmarkets/bom-postgres \
    regentmarkets/bom-websocket-tests \
    binary-com/translations-websockets-api \
    regentmarkets/bom-market \
    regentmarkets/php-mt5-webapi \
    regentmarkets/bom-transaction \
    regentmarkets/bom-pricing

/tmp/travis-scripts/redis.sh
