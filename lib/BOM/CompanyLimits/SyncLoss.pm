package BOM::CompanyLimits::SyncLoss;

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
use BOM::CompanyLimits::Helpers qw(get_redis);

# Certain loss types reset at the start of a new day. We use a cron
# to periodically set expiryat in redis. For unit tests, we pass a
# param force_reset to delete the hashes immediately.
sub reset_daily_loss_hashes {
    my %params = @_;

    my $new_day_start_epoch = Date::Utility::today()->epoch + 86400;
    my %output;

    foreach my $loss_type (qw/realized_loss turnover/) {
        foreach my $landing_company (qw/svg malta maltainvest iom/) {
            my $redis = get_redis($landing_company, $loss_type);
            my $hash_name = "$landing_company:$loss_type";

            if ($params{force_reset}) {
                $output{$hash_name} = $redis->expireat($hash_name, $new_day_start_epoch);
            } else {
                $output{$hash_name} = $redis->del($hash_name);
            }
        }
    }

    return %output;
}

sub get_db_potential_loss {
# TODO
}

sub get_db_realized_loss {
# TODO
}

sub get_db_turnover {
# TODO
}

sub sync_potential_loss_to_redis {
# TODO
}

sub update_ultrashort_duration {
# TODO: Ultrashort will be global setting: a range of time between 1-1800 seconds.
#       All expiry_type that is ultrashort and intraday has to be updated in Redis
#       to be in sync with the database. This could potentially update tens of thousands
#       of keys, so we do not expect ultrashort duration to change too often
}

1;
