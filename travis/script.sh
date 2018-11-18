#!/bin/bash
# script.sh - Travis setup for script phase
# See https://docs.travis-ci.com/user/job-lifecycle

set -ex

join() { local IFS="$1"; shift; echo "$*"; }

export PATH=/etc/rmg/bin:/home/git/regentmarkets/cpan/local/bin:$PATH
# shellcheck disable=SC2046
PERL5LIB=$(join : $(ls -d /home/git/regentmarkets/bom**/lib))
export PERL5LIB
export RPC_CONFIG=$PWD/rpc.conf.travis
/etc/rmg/bin/perl -V ; command -v perl ; ls -l /etc/rmg/bin
if [ "$TEST_SUITE" = "" ]; then true; else make "$TEST_SUITE"; fi
