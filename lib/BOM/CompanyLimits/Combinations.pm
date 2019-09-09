package BOM::CompanyLimits::Combinations;

use strict;
use warnings;
use BOM::CompanyLimits::Helpers qw(get_redis);

sub get_limit_settings_combinations {
    my ($binary_user_id, $underlying_group, $underlying, $contract_group, $expiry_type, $barrier_type) = @{+shift};

    my $g = '%s%s,%s,%s';
    my $u = "%s,%s,$binary_user_id";
    return [
        # Global limits
        sprintf($g, $expiry_type, $barrier_type, $underlying,       $contract_group),
        sprintf($g, $expiry_type, $barrier_type, $underlying,       '+'),
        sprintf($g, $expiry_type, $barrier_type, $underlying_group, $contract_group),
        sprintf($g, $expiry_type, $barrier_type, $underlying_group, '+'),
        sprintf($g, $expiry_type, $barrier_type, '+',               $contract_group),
        sprintf($g, $expiry_type, $barrier_type, '+',               '+'),
        sprintf($g, $expiry_type, '+',           $underlying,       $contract_group),
        sprintf($g, $expiry_type, '+',           $underlying,       '+'),
        sprintf($g, $expiry_type, '+',           $underlying_group, $contract_group),
        sprintf($g, $expiry_type, '+',           $underlying_group, '+'),
        sprintf($g, $expiry_type, '+',           '+',               $contract_group),
        sprintf($g, $expiry_type, '+',           '+',               '+'),
        sprintf($g, '+',          $barrier_type, $underlying,       $contract_group),
        sprintf($g, '+',          $barrier_type, $underlying,       '+'),
        sprintf($g, '+',          $barrier_type, $underlying_group, $contract_group),
        sprintf($g, '+',          $barrier_type, $underlying_group, '+'),
        sprintf($g, '+',          $barrier_type, '+',               $contract_group),
        sprintf($g, '+',          $barrier_type, '+',               '+'),
        sprintf($g, '+',          '+',           $underlying,       $contract_group),
        sprintf($g, '+',          '+',           $underlying,       '+'),
        sprintf($g, '+',          '+',           $underlying_group, $contract_group),
        sprintf($g, '+',          '+',           $underlying_group, '+'),
        sprintf($g, '+',          '+',           '+',               $contract_group),
        sprintf($g, '+',          '+',           '+',               '+'),
        # User specific limits
        sprintf($u, $expiry_type, $underlying_group),
        sprintf($u, $expiry_type, '+'),
        sprintf($u, '+',          $underlying_group),
        sprintf($u, '+',          '+'),
    ];
}

# turnover limits require special handling; though we use the same keys to query
# its limits settings, we infer that turnover limits only apply per user per
# underlying and exclude barrier type; this meant that the same increments applied
# globally can also be reused for user specific turnover limits. This is done by
# checking with turnover increments in which contract group is '+'. Although user
# specific limits is set per underlying group, we infer that it is applied per
# underlying (underlying group specific, underlying = '*').
sub get_turnover_incrby_combinations {
    # NOTE: underlying_group is never used here
    my ($binary_user_id, undef, $underlying, $contract_group, $expiry_type) = @{+shift};

    my $turnover_format = "%s,$underlying,%s,$binary_user_id";
    return [
        sprintf($turnover_format, $expiry_type, $contract_group),
        sprintf($turnover_format, $expiry_type, '+'),
        sprintf($turnover_format, '+',          $contract_group),
        sprintf($turnover_format, '+',          '+'),
    ];
}

sub _get_attr_groups {
    my ($contract)      = @_;
    my $bet_data        = $contract->{bet_data};
    my $landing_company = $contract->{account_data}->{landing_company};

    my ($contract_group, $underlying_group);
    my $redis = get_redis($landing_company, 'limit_setting');

    $redis->hget(
        'contractgroups',
        $bet_data->{bet_type},
        sub {
            $contract_group = $_[1];
        });
    $redis->hget(
        'underlyinggroups',
        $bet_data->{underlying_symbol},
        sub {
            $underlying_group = $_[1];
        });
    $redis->mainloop;

    return ($contract_group, $underlying_group);
}

sub get_attributes_from_contract {
    my ($contract) = @_;

    my ($contract_group, $underlying_group) = _get_attr_groups($contract);

    if (not $underlying_group) {
        die ['BI054'];    # mimic database error
    }

    # TODO: This error code is not mapped to any error object in Transaction.pm
    #       nor unit tested. Might want to look into that.
    if (not $contract_group) {
        die ['BI053'];    # Error: 'bet_type %s not found in bet.contract_group table'
    }

    my $bet_data       = $contract->{bet_data};
    my $underlying     = $bet_data->{underlying_symbol};
    my $binary_user_id = $contract->{account_data}->{binary_user_id};

    # a for atm, n for non-atm
    my $barrier_type = ($bet_data->{short_code} =~ /_SOP_/) ? 'a' : 'n';

    my $expiry_type = 'i';    # intraday
    if ($bet_data->{tick_count} and $bet_data->{tick_count} > 0) {
        $expiry_type = 't';    # tick
    } elsif ($bet_data->{expiry_daily}) {
        $expiry_type = 'd';    # daily
    } else {
        my $duration = Date::Utility->new($bet_data->{expiry_time})->epoch - Date::Utility->new($bet_data->{start_time})->epoch;
        $expiry_type = 'u' if ($duration <= 300);    # ultra_short; 5 minutes
    }

    return [$binary_user_id, $underlying_group, $underlying, $contract_group, $expiry_type, $barrier_type];
}

1;
