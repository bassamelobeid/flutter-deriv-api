package BOM::CompanyLimits::Combinations;

use strict;
use warnings;

use BOM::CompanyLimits::Groups;
use BOM::CompanyLimits::Helpers qw(get_redis);

sub get_global_limit_combinations {
    my ($attributes) = @_;
    my ($underlying_group, $underlying, $contract_group, $expiry_type, $barrier_type) = @$attributes;

    my $g = '%s%s,%s,%s';
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
    ];
}

sub get_user_limit_combinations {
    my ($binary_user_id, $attributes) = @_;
    my ($underlying_group, $expiry_type) = @{$attributes}[0, 3];

    my $u = "%s,%s,$binary_user_id";

    return [sprintf($u, $expiry_type, $underlying_group), sprintf($u, $expiry_type, '+'), sprintf($u, '+', $underlying_group),
        sprintf($u, '+', '+'),];
}

# turnover limits require special handling; though we use the same keys to query
# its limits settings, we infer that turnover limits only apply per user per
# underlying and exclude barrier type; this meant that the same increments applied
# globally can also be reused for user specific turnover limits. This is done by
# checking with turnover increments in which contract group is '+'. Although user
# specific limits is set per underlying group, we infer that it is applied per
# underlying (underlying group specific, underlying = '*').
sub get_turnover_incrby_combinations {
    my ($binary_user_id, $attributes) = @_;
    my ($underlying, $contract_group, $expiry_type) = @{$attributes}[1 .. 3];

    my $turnover_format = "%s,$underlying,%s,$binary_user_id";
    return [
        sprintf($turnover_format, $expiry_type, $contract_group),
        sprintf($turnover_format, $expiry_type, '+'),
        sprintf($turnover_format, '+',          $contract_group),
        sprintf($turnover_format, '+',          '+'),
    ];
}

sub get_attributes_from_contract {
    my ($bet_data) = @_;

    my ($contract_group, $underlying_group) = BOM::CompanyLimits::Groups::get_limit_groups($bet_data);

    if (not $underlying_group) {
        die ['BI054'];    # mimic database error
    }

    # TODO: This error code is not mapped to any error object in Transaction.pm
    #       nor unit tested. Might want to look into that.
    if (not $contract_group) {
        die ['BI053'];    # Error: 'bet_type %s not found in bet.contract_group table'
    }

    my $underlying = $bet_data->{underlying_symbol};

    # a for atm, n for non-atm
    my $barrier_type = ($bet_data->{short_code} =~ /_S0P_/) ? 'a' : 'n';

    my $expiry_type = 'i';    # intraday
    if ($bet_data->{tick_count} and $bet_data->{tick_count} > 0) {
        $expiry_type = 't';    # tick
    } elsif ($bet_data->{expiry_daily}) {
        $expiry_type = 'd';    # daily
    } else {
        my $duration = Date::Utility->new($bet_data->{expiry_time})->epoch - Date::Utility->new($bet_data->{start_time})->epoch;
        # TODO: ultra_short will be become a flexible value in the future. This part of the code
        #       needs to be able to accomodate this eventually.
        $expiry_type = 'u' if ($duration <= 300);    # ultra_short; 5 minutes
    }

    return [$underlying_group, $underlying, $contract_group, $expiry_type, $barrier_type];
}

1;
