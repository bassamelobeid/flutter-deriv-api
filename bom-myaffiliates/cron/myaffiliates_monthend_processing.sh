#!/bin/bash
# The two following processes need to be run in the following order.
# To ensure that, ONE cronjob will be executed rather than two.

. /etc/profile.d/perl5.sh
cd /home/git/regentmarkets/bom-myaffiliates
/etc/rmg/bin/perl -I/lib cron/myaffiliates_token_import.pl 1> /tmp/myaffiliates_token_import

echo 'myaffiliates_commission run processed: '$(psql service=collector01 -Xt -v ON_ERROR_STOP=1 <<<'SELECT data_collection.calculate_affiliate_commission()')
