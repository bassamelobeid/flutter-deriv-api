#!/etc/rmg/bin/perl

use strict;
use warnings;

# This script is part of the company limits system, and should run in the server containing
# the Redis instance with the loss hashes. It is called by cron 'expire_realized_loss_and_turnover'.
# Realized loss and turnover needs to be reset at the start of a new day as we only factor these
# losses for the current day only. As the script simply sets expiry time, it is safe to repeatedly
# run this - in fact the cron actually runs more than once a day. It is safer to do so, particularly
# for landing companies in which there are only a couple of trades a day; the hash keys only exist
# when are buys and sells.
#
# The script outputs the result of setting expireat for every possible realized loss and turnover
# hash. We would expect for active landing companies with trades happening that the result will
# always be 1. It is possible that it could be 0 even if they are active landing companies - if
# there are no buys/sells from when the hash is removed till the expiry is set (at which point
# the hash does not exist), or simply that the wrong key is being set.
#
# It is possible to simply delete the hashes precisely at midnight, but you can never precisely
# delete the hash at some time with as much precision as you would have Redis do it.

use Log::Any qw($log);
use BOM::Transaction::Limits::SyncLoss;
use Log::Any::Adapter qw(Stdout), log_level => 'info';

my $output = BOM::Transaction::Limits::SyncLoss::reset_daily_loss_hashes();

$log->info(sprintf "%s: %s", $_, $output->{$_})
    for (sort keys %$output);

exit 0;
