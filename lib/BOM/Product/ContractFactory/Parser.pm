package BOM::Product::ContractFactory::Parser;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
    shortcode_to_parameters
);

use BOM::Product::Contract::Strike;

=head1 NAME

BOM::Product::ContractFactory::Parser

=head1 DESCRIPTION

Some general utility subroutines related to bet parameters.

=cut

use Date::Utility;
use LandingCompany::Offerings qw(get_all_contract_types);
use BOM::Platform::Runtime;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use LandingCompany::Registry;
use List::MoreUtils qw(uniq);

=head2 shortcode_to_parameters

Convert a shortcode and currency pair into parameters suitable for creating a BOM::Product::Contract

=cut

sub shortcode_to_parameters {
    my ($shortcode, $currency, $is_sold) = @_;

    my (
        $bet_type, $underlying_symbol, $payout,       $date_start,  $date_expiry,    $barrier,
        $barrier2, $prediction,        $fixed_expiry, $tick_expiry, $how_many_ticks, $forward_start,
    );

    # legacy shortcode, something to do with bet exchange
    if ($shortcode =~ /^(.+)_E$/) {
        $shortcode = $1;
    }

    my ($test_bet_name, $test_bet_name2) = split /_/, $shortcode;

    # for CLUB, it does not have '_' which will not be captured in code above
    # we need to handle it separately
    if ($shortcode =~ /^CLUB/i) {
        $test_bet_name = 'CLUB';
    }
    my %OVERRIDE_LIST = (
        INTRADU    => 'CALL',
        INTRADD    => 'PUT',
        FLASHU     => 'CALL',
        FLASHD     => 'PUT',
        DOUBLEUP   => 'CALL',
        DOUBLEDOWN => 'PUT',
    );
    $test_bet_name = $OVERRIDE_LIST{$test_bet_name} if exists $OVERRIDE_LIST{$test_bet_name};

    my $legacy_params = {
        bet_type   => 'Invalid',    # it doesn't matter what it is if it is a legacy
        underlying => 'config',
        currency   => $currency,
    };

    return $legacy_params if (not exists get_all_contract_types()->{$test_bet_name} or $shortcode =~ /_\d+H\d+/);

    if ($shortcode =~ /^(SPREADU|SPREADD)_([\w\d]+)_(\d*.?\d*)_(\d+)_(\d*.?\d*)_(\d*.?\d*)_(DOLLAR|POINT)/) {
        return {
            shortcode        => $shortcode,
            bet_type         => $1,
            underlying       => create_underlying($2),
            amount_per_point => $3,
            date_start       => $4,
            stop_loss        => $5,
            stop_profit      => $6,
            stop_type        => lc $7,
            currency         => $currency,
            is_sold          => $is_sold
        };
    }

    # Legacy shortcode: purchase is a date string e.g. '01-Jan-01'.
    if ($shortcode =~ /^([^_]+)_([\w\d]+)_(\d+)_(\d\d?)_(\w\w\w)_(\d\d)_(\d\d?)_(\w\w\w)_(\d\d)_(S?-?\d+P?)_(S?-?\d+P?)$/) {
        $bet_type          = $1;
        $underlying_symbol = $2;
        $payout            = $3;
        $date_start        = uc($4 . '-' . $5 . '-' . $6);
        $date_expiry       = uc($7 . '-' . $8 . '-' . $9);
        $barrier           = $10;
        $barrier2          = $11;

        $date_start = Date::Utility->new($date_start)->epoch;
    }

    # Both purchase and expiry date are timestamp (e.g. a 30-min bet)
    elsif ($shortcode =~ /^([^_]+)_([\w\d]+)_(\d*\.?\d*)_(\d+)(?<start_cond>F?)_(\d+)(?<expiry_cond>[FT]?)_(S?-?\d+P?)_(S?-?\d+P?)$/) {
        $bet_type          = $1;
        $underlying_symbol = $2;
        $payout            = $3;
        $date_start        = $4;
        $forward_start     = 1 if $+{start_cond} eq 'F';
        $barrier           = $8;
        $barrier2          = $9;
        $fixed_expiry      = 1 if $+{expiry_cond} eq 'F';
        if ($+{expiry_cond} eq 'T') {
            $tick_expiry    = 1;
            $how_many_ticks = $6;
        } else {
            $date_expiry = $6;
        }
    }

    # Purchase date is timestamp but expiry date is date string
    elsif ($shortcode =~ /^([^_]+)_([\w\d]+)_(\d*\.?\d{1,2})_(\d+)_(\d\d?)_(\w\w\w)_(\d\d)_(S?-?\d+P?)_(S?-?\d+P?)$/) {
        $bet_type          = $1;
        $underlying_symbol = $2;
        $payout            = $3;
        $date_start        = $4;
        $date_expiry       = uc($5 . '-' . $6 . '-' . $7);
        $barrier           = $8;
        $barrier2          = $9;
        $fixed_expiry      = 1;                              # This automatically defaults to fixed expiry
    }

    # Contract without barrier
    elsif ($shortcode =~ /^([^_]+)_(R?_?[^_\W]+)_(\d*\.?\d*)_(\d+)_(\d+)(?<expiry_cond>[T]?)$/) {
        $bet_type          = $1;
        $underlying_symbol = $2;
        $payout            = $3;
        $date_start        = $4;
        if ($+{expiry_cond} eq 'T') {
            $tick_expiry    = 1;
            $how_many_ticks = $5;
        }
    } else {
        return $legacy_params;
    }

    my $underlying = create_underlying($underlying_symbol);
    $barrier = BOM::Product::Contract::Strike->strike_string($barrier, $underlying, $bet_type, $date_start)
        if defined $barrier;
    $barrier2 = BOM::Product::Contract::Strike->strike_string($barrier2, $underlying, $bet_type, $date_start)
        if defined $barrier2;
    my %barriers =
        ($barrier and $barrier2)
        ? (
        high_barrier => $barrier,
        low_barrier  => $barrier2
        )
        : (defined $barrier) ? (barrier => $barrier)
        :                      ();

    my $bet_parameters = {
        shortcode    => $shortcode,
        bet_type     => $bet_type,
        underlying   => $underlying,
        amount_type  => 'payout',
        amount       => $payout,
        date_start   => $date_start,
        date_expiry  => $date_expiry,
        prediction   => $prediction,
        currency     => $currency,
        fixed_expiry => $fixed_expiry,
        tick_expiry  => $tick_expiry,
        tick_count   => $how_many_ticks,
        is_sold      => $is_sold,
        ($forward_start) ? (starts_as_forward_starting => $forward_start) : (),
        %barriers,
    };

    return $bet_parameters;
}

1;
