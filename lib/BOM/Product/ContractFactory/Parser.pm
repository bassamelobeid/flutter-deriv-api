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
use BOM::Platform::Runtime;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Finance::Contract::Category;
use LandingCompany::Registry;
use List::MoreUtils qw(uniq);
use Date::Utility;

=head2 shortcode_to_parameters

Convert a shortcode and currency pair into parameters suitable for creating a BOM::Product::Contract

=cut

sub shortcode_to_parameters {
    my ($shortcode, $currency, $is_sold) = @_;

    my ($bet_type, $underlying_symbol, $payout, $date_start, $date_expiry, $barrier, $barrier2, $prediction, $fixed_expiry, $tick_expiry,
        $how_many_ticks, $forward_start, $binaryico_per_token_bid_price,
        $binaryico_number_of_tokens, $unit);

    my ($initial_bet_type) = split /_/, $shortcode;

    my $legacy_params = {
        bet_type   => 'Invalid',    # it doesn't matter what it is if it is a legacy
        underlying => 'config',
        currency   => $currency,
    };

    return $legacy_params if (not exists Finance::Contract::Category::get_all_contract_types()->{$initial_bet_type} or $shortcode =~ /_\d+H\d+/);

    # Non binary parser
    my $nonbinary_list = 'LBFIXEDCALL|LBFIXEDPUT|LBFLOATCALL|LBFLOATPUT|LBHIGHLOW';
    if ($shortcode =~ /^($nonbinary_list)_(\w+)_(\d*\.?\d*)_(\d+)(?<start_cond>F?)_(\d+)(?<expiry_cond>[FT]?)_(S?-?\d+P?)_(S?-?\d+P?)$/) {
        $unit = $3;
    }

    if ($shortcode =~ /^([^_]+)_([\w\d]+)_(\d*\.?\d*)_(\d+)(?<start_cond>F?)_(\d+)(?<expiry_cond>[FT]?)_(S?-?\d+P?)_(S?-?\d+P?)$/) {

        # Both purchase and expiry date are timestamp (e.g. a 30-min bet)

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
    } elsif ($shortcode =~ /^BINARYICO_(\d+\.?\d*)_(\d+)$/) {
        $bet_type                      = 'BINARYICO';
        $underlying_symbol             = 'BINARYICO';
        $binaryico_per_token_bid_price = $1;
        $binaryico_number_of_tokens    = $2;

    }

    else {
        return $legacy_params;
    }

    my $underlying = create_underlying($underlying_symbol);
    $barrier = BOM::Product::Contract::Strike->strike_string($barrier, $underlying, $bet_type)
        if defined $barrier;
    $barrier2 = BOM::Product::Contract::Strike->strike_string($barrier2, $underlying, $bet_type)
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
        amount_type  => $bet_type eq 'BINARYICO' ? 'stake' : 'payout',
        amount       => $bet_type eq 'BINARYICO' ? $binaryico_per_token_bid_price : $payout,
        (defined $unit) ? (unit => $unit) : (),

        date_start   => $date_start,
        date_expiry  => $date_expiry,
        prediction   => $prediction,
        currency     => $currency,
        fixed_expiry => $fixed_expiry,
        tick_expiry  => $tick_expiry,
        tick_count   => $how_many_ticks,
        is_sold      => $is_sold,
        ($forward_start) ? (starts_as_forward_starting => $forward_start) : (),
        (
            $bet_type eq 'BINARYICO'
            ? (
                binaryico_number_of_tokens    => $binaryico_number_of_tokens,
                binaryico_per_token_bid_price => $binaryico_per_token_bid_price
                )
            : ()
        ),
        %barriers,
    };

    return $bet_parameters;
}

1;
