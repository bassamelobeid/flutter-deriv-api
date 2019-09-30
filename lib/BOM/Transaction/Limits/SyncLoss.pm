package BOM::Transaction::Limits::SyncLoss;

use strict;
use warnings;

# All code here deals with syncing loss hashes in redis.
# In production, perl scripts using methods here are called via
# crons (possibly daemons in the future) to ensure redis data to
# periodically aligned with the ground truth (database).
#
# We can _never_ assert that what is in Redis is 100% reliable.
# Connection failures, server malfunctions and other unexpected
# crap can cause values in loss type hashes to be out of sync.

use Date::Utility;
use BOM::Config::TransactionLimits;
use LandingCompany::Registry;

# Certain loss types reset at the start of a new day. We use a cron
# to periodically set expiryat in redis. For unit tests, we pass a
# param force_reset to delete the hashes immediately.
sub reset_daily_loss_hashes {
    my %params = @_;

    my $new_day_start_epoch = Date::Utility::today()->epoch + 86400;
    my %output;

    my $redis;
    my @landing_companies_with_broker_codes = grep { $#{$_->broker_codes} > -1 } LandingCompany::Registry::all();
    foreach my $loss_type (qw/realized_loss turnover/) {
        foreach my $lc (@landing_companies_with_broker_codes) {
            $redis = BOM::Config::TransactionLimits::redis_limits_write($lc);
            my $landing_company = $lc->{short};
            my $hash_name       = "$landing_company:$loss_type";

            if ($params{force_reset}) {
                $output{$hash_name} = $redis->del($hash_name);
            } else {
                $output{$hash_name} = $redis->expireat($hash_name, $new_day_start_epoch);
            }
        }
    }

    return \%output;
}

1;
