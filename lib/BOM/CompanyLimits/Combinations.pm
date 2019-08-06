package BOM::CompanyLimits::Combinations;

use strict;
use warnings;
use BOM::CompanyLimits::Helpers qw(get_redis);

# TODO: This is going to be changed quite a bit with the new spec
sub get_combinations {
    my ($contract) = @_;

    my ($contract_group, $underlying_group) = _get_attr_groups($contract);
    my $bet_data   = $contract->{bet_data};
    my $underlying = $bet_data->{underlying_symbol};

    my $is_atm = ($bet_data->{short_code} =~ /_SOP_/) ? 't' : 'f';

    my $expiry_type;
    if ($bet_data->{tick_count} and $bet_data->{tick_count} > 0) {
        $expiry_type = 'tick';
    } elsif ($bet_data->{expiry_daily}) {
        $expiry_type = 'daily';
    } elsif ((Date::Utility->new($bet_data->{expiry_time})->epoch - Date::Utility->new($bet_data->{start_time})->epoch) <= 300) {    # 5 minutes
        $expiry_type = 'ultra_short';
    } else {
        $expiry_type = 'intraday';
    }

    my @attributes = ($underlying, $contract_group, $expiry_type, $is_atm);
    my @combinations = _get_all_key_combinations(@attributes);

    # Merge another array that substitutes underlying with underlying group
    # Since we know that the 1st attribute is the underlying, each index in which
    # the 1st bit is 1 has underlying:
    my @underlyinggroup_combinations;
    my $underlying_len = length($underlying);
    foreach my $i (1 .. scalar @combinations) {
        if (($i & 1) == 1) {
            my $k = $underlying_group . substr($combinations[$i - 1], $underlying_len);
            push(@underlyinggroup_combinations, $k);
        }
    }

    return (@combinations, @underlyinggroup_combinations);
}

sub _get_attr_groups {
    my ($contract)      = @_;
    my $bet_data        = $contract->{bet_data};
    my $landing_company = $contract->{account_data}->{landing_company};

    my ($contract_group, $underlying_group);
    my $redis = get_redis($landing_company, 'limit_setting');
    $redis->hget(
        'CONTRACTGROUPS',
        $bet_data->{bet_type},
        sub {
            $contract_group = $_[1];
        });
    $redis->hget(
        'UNDERLYINGGROUPS',
        $bet_data->{underlying_symbol},
        sub {
            $underlying_group = $_[1];
        });
    $redis->mainloop;

    return ($contract_group, $underlying_group);
}

sub _get_all_key_combinations {
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

1;
