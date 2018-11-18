#!/bin/bash
# script.sh - Travis setup for script phase
# See https://docs.travis-ci.com/user/job-lifecycle

set -ex

join() { local IFS=$1; shift; echo "$*"; }

export PATH=/etc/rmg/bin:/home/git/regentmarkets/cpan/local/bin:$PATH
# shellcheck disable=SC2046
PERL5LIB=$(join : $(ls -d /home/git/regentmarkets/bom**/lib))
export PERL5LIB="/home/git/regentmarkets/binary-websocket-api/lib:$PERL5LIB"
export WEBSOCKET_CONFIG=$PWD/websocket.conf.example

/etc/rmg/bin/perl -V ; command -v perl ; ls -l /etc/rmg/bin

perl /home/git/regentmarkets/bom-platform/bin/notify_pub.pl 2>&1 | grep -Ev '(connection has been closed unexpectedly)|(terminating connection due to administrator)' &
perl /home/git/regentmarkets/bom-pricing/bin/price_queue.pl   daemon > /dev/null 2>&1 &
perl /home/git/regentmarkets/bom-pricing/bin/price_daemon.pl --no-warmup=1 daemon > /dev/null 2>&1 &

if [ "$TEST_SUITE" = "" ]; then true; else make "$TEST_SUITE"; fi
