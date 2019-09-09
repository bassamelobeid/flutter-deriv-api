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
    # NOTE: limit_setting should be the same server for all landing companies.
    #       This is where we store underlying and contract groups as well
    state $redis            = BOM::Config::RedisReplicated::redis_limits_write;
    state $limits_redis_map = {
        svg => {
            potential_loss => $redis,
            realized_loss  => $redis,
            turnover       => $redis,
            limit_setting  => $redis,
        },
        malta => {
            potential_loss => $redis,
            realized_loss  => $redis,
            turnover       => $redis,
            limit_setting  => $redis,
        },
        maltainvest => {
            potential_loss => $redis,
            realized_loss  => $redis,
            turnover       => $redis,
            limit_setting  => $redis,
        },
        iom => {
            potential_loss => $redis,
            realized_loss  => $redis,
            turnover       => $redis,
            limit_setting  => $redis,
        },
        virtual => {
            potential_loss => $redis,
            realized_loss  => $redis,
            turnover       => $redis,
            limit_setting  => $redis,
        },
    };

    my $redis_instance = $limits_redis_map->{$landing_company}->{$purpose};
    die "Unable to locate redis instance for $landing_company:$purpose" unless $redis_instance;

    return $redis_instance;
}

1;
