package BOM::CompanyLimits::Helpers;
use BOM::Config::RedisReplicated;
use strict;
use warnings;
use 5.010;

sub get_all_key_combinations {
    my (@a, $delim) = @_;
    $delim ||= ',';

    my @combinations;
    foreach my $i (1 .. (1 << scalar @a) - 1) {
        my $combination;
        foreach my $j (0 .. $#a) {
            my $k = (1 << $j);
            my $c = (($i & $k) == $k) ? $a[$j] : '';
            $combination = ($j == 0 ? "$c" : "$combination$delim$c");
        }
        push @combinations, $combination;
    }

    return @combinations;
}


sub get_redis {
    my ($landing_company, $purpose) = @_;

    if (BOM::Config->env() =~ /(^development$)|(^qa)/) {
        state $redis = BOM::Config::RedisReplicated::redis_limits_write;
        return $redis;
    }

    # Should we enable sharding for limits, this is the place to set
    state $redis = BOM::Config::RedisReplicated::redis_limits_write;
    state $limits_redis_map = {
        svg => {
            potential_loss => $redis,
            realized_loss => $redis,
            turnover => $redis,
            limit_setting => $redis,
        },
        mlt => {
            potential_loss => $redis,
            realized_loss => $redis,
            turnover => $redis,
            limit_setting => $redis,
        },
        mf => {
            potential_loss => $redis,
            realized_loss => $redis,
            turnover => $redis,
            limit_setting => $redis,
        },
        mx => {
            potential_loss => $redis,
            realized_loss => $redis,
            turnover => $redis,
            limit_setting => $redis,
        },
    };

    return $limits_redis_map->{$landing_company}->{$purpose};
}

1;
