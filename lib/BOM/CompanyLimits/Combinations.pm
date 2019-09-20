package BOM::CompanyLimits::Combinations;

use strict;
use warnings;

use BOM::CompanyLimits::Groups;

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

    my $user_format = "%s,%s,$binary_user_id";

    return [
        sprintf($user_format, $expiry_type, $underlying_group),
        sprintf($user_format, $expiry_type, '+'),
        sprintf($user_format, '+',          $underlying_group),
        sprintf($user_format, '+',          '+'),
    ];
}

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
        $underlying_group = 'default';
    }

    if (not $contract_group) {
        $contract_group = 'default';
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
