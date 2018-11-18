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

echo "never" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
sudo /etc/init.d/ntp stop

/tmp/travis-scripts/websocket_schema_update.sh
export API_TOKEN=cd1bec02529c7f8780ef5fbb41dc48cacc4d4942

/tmp/travis-scripts/parallel_clone_branch.sh \
    regentmarkets/bom-test \
    regentmarkets/bom-websocket-tests \
    regentmarkets/bom \
    regentmarkets/bom-config \
    regentmarkets/bom-platform \
    regentmarkets/bom-user \
    regentmarkets/bom-feed \
    regentmarkets/bom-populator \
    regentmarkets/bom-rpc \
    regentmarkets/bom-postgres \
    regentmarkets/bom-pricing \
    regentmarkets/bom-market \
    regentmarkets/bom-transaction \
    regentmarkets/php-mt5-webapi \
    binary-com/translations-websockets-api

/tmp/travis-scripts/redis.sh
