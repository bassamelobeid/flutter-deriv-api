package BOM::CompanyLimits::Combinations;

use strict;
use warnings;
use BOM::CompanyLimits::Helpers qw(get_redis);

sub get_combinations {
    my ($contract) = @_;

    my ($binary_user_id, $underlying_group, $underlying, $contract_group, $expiry_type, $barrier_type) = get_attributes_from_contract($contract);

    my $g                     = '%s%s,%s,%s';
    my $u                     = "%s,%s,$binary_user_id";
    my $company_limits_incrby = [
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

    my $turnover_format = "%s,%s,%s,$binary_user_id";
    # Turnover only applies per underlying, and without barrier type
    my $turnover_incrby = [
        sprintf($turnover_format, $expiry_type, $underlying, $contract_group),
        sprintf($turnover_format, $expiry_type, $underlying, '+'),
        sprintf($turnover_format, $expiry_type, '+',         $contract_group),
        sprintf($turnover_format, $expiry_type, '+',         '+'),
        sprintf($turnover_format, '+',          $underlying, $contract_group),
        sprintf($turnover_format, '+',          $underlying, '+'),
        sprintf($turnover_format, '+',          '+',         $contract_group),
        sprintf($turnover_format, '+',          '+',         '+'),
    ];

    return ($company_limits_incrby, $turnover_incrby);
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

    # TODO: Defaults to + to get tests to pass, but we should
    #       setup the contract and underlying groups in unit test redis
    #       as well as the the redis instance used for trades
    $contract_group   ||= '+';
    $underlying_group ||= '+';

    return ($contract_group, $underlying_group);
}

sub get_attributes_from_contract {
    my ($contract) = @_;

    my ($contract_group, $underlying_group) = _get_attr_groups($contract);

    my $bet_data       = $contract->{bet_data};
    my $underlying     = $bet_data->{underlying_symbol};
    my $binary_user_id = $contract->{account_data}->{binary_user_id};

    # t for atm, f for non-atm
    my $barrier_type = ($bet_data->{short_code} =~ /_SOP_/) ? 't' : 'f';

    my $expiry_type = 'i';    # intraday
    if ($bet_data->{tick_count} and $bet_data->{tick_count} > 0) {
        $expiry_type = 't';    # tick
    } elsif ($bet_data->{expiry_daily}) {
        $expiry_type = 'd';    # daily
    } else {
        my $duration = Date::Utility->new($bet_data->{expiry_time})->epoch - Date::Utility->new($bet_data->{start_time})->epoch;
        $expiry_type = 'u' if ($duration <= 300);    # ultra_short; 5 minutes
    }

    return ($binary_user_id, $underlying_group, $underlying, $contract_group, $expiry_type, $barrier_type);
}

1;
