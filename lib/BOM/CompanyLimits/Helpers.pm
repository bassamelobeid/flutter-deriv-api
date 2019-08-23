package BOM::CompanyLimits::Helpers;

use strict;
use warnings;
use 5.010;

use BOM::Config::RedisReplicated;
use Exporter qw(import);

our @EXPORT_OK = qw(get_redis);

sub get_redis {
    my ($landing_company, $purpose) = @_;

    if (BOM::Config->env() =~ /(^development$)|(^qa)/) {
        state $redis = BOM::Config::RedisReplicated::redis_limits_write;
        return $redis;
    }

    # Should we enable sharding for limits, this is the place to set
    state $redis            = BOM::Config::RedisReplicated::redis_limits_write;
    state $limits_redis_map = {
        svg => {
            potential_loss => $redis,
            realized_loss  => $redis,
            turnover       => $redis,
            limit_setting  => $redis,
        },
        mlt => {
            potential_loss => $redis,
            realized_loss  => $redis,
            turnover       => $redis,
            limit_setting  => $redis,
        },
        mf => {
            potential_loss => $redis,
            realized_loss  => $redis,
            turnover       => $redis,
            limit_setting  => $redis,
        },
        mx => {
            potential_loss => $redis,
            realized_loss  => $redis,
            turnover       => $redis,
            limit_setting  => $redis,
        },
    };

    return $limits_redis_map->{$landing_company}->{$purpose};
}

1;
