package BOM::Product::ContractFactory::Parser;

use strict;
use warnings;

use Carp;

use Exporter 'import';
our @EXPORT_OK = qw(
    shortcode_to_parameters
    financial_market_bet_to_parameters
);

use BOM::Product::Contract::Strike;

=head1 NAME

BOM::Product::ContractFactory::Parser

=head1 DESCRIPTION

Some general utility subroutines related to bet parameters.

=cut

use Date::Utility;
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Market::Underlying;
use BOM::Database::Model::Constants;
use BOM::Platform::Runtime::LandingCompany::Registry;
use List::MoreUtils qw(uniq);

=head2 financial_market_bet_to_parameters

Convert an FMB into parameters suitable for creating a BOM::Product::Contract

=cut

my @available_contracts =
    map { get_offerings_with_filter('contract_type', {landing_company => $_->short}) } BOM::Platform::Runtime::LandingCompany::Registry->new->all;
my %AVAILABLE_CONTRACTS = map { $_ => 1 } uniq(@available_contracts);

sub financial_market_bet_to_parameters {
    my $fmb      = shift;
    my $currency = shift;
    croak 'Expected BOM::Database::Model::FinancialMarketBet instance.'
        if not $fmb->isa('BOM::Database::Model::FinancialMarketBet');

    # don't bother to get legacy parameters; rather we can just use shortcode
    if ($fmb->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_LEGACY_BET) {
        return shortcode_to_parameters($fmb->short_code, $currency, $fmb->is_sold);
    }

    my $underlying     = BOM::Market::Underlying->new($fmb->underlying_symbol);
    my $bet_parameters = {
        bet_type    => $fmb->bet_type,
        underlying  => $underlying,
        amount_type => 'payout',
        amount      => $fmb->payout_price,
        currency    => $currency,
        is_sold     => $fmb->is_sold
    };

    my $purchase_time       = Date::Utility->new($fmb->purchase_time);
    my $contract_start_time = Date::Utility->new($fmb->start_time->epoch);
    # since a forward starting contract needs to start 5 minutes in the future,
    # 5 seconds is a safe mark.
    if ($contract_start_time->epoch - $purchase_time->epoch > 5) {
        $bet_parameters->{is_forward_starting} = 1;
    }
    $bet_parameters->{date_start} = $contract_start_time;
    $bet_parameters->{date_expiry} = Date::Utility->new($fmb->expiry_time->epoch) if $fmb->expiry_time;

    if ($fmb->tick_count) {
        $bet_parameters->{tick_expiry} = 1;
        $bet_parameters->{tick_count}  = $fmb->tick_count;
    }

    if ($fmb->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_HIGHER_LOWER_BET) {
        if (defined $fmb->relative_barrier) {
            $bet_parameters->{barrier} = $fmb->relative_barrier;
        } elsif (defined $fmb->absolute_barrier) {
            $bet_parameters->{barrier} = $fmb->absolute_barrier;
        }
    } elsif ($fmb->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_DIGIT_BET) {
        $bet_parameters->{'barrier'} = $fmb->last_digit;
    } elsif ($fmb->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_RANGE_BET) {
        $bet_parameters->{'high_barrier'} =
              $fmb->relative_higher_barrier
            ? $fmb->relative_higher_barrier
            : $fmb->absolute_higher_barrier;
        $bet_parameters->{'low_barrier'} =
              $fmb->relative_lower_barrier
            ? $fmb->relative_lower_barrier
            : $fmb->absolute_lower_barrier;
    } elsif ($fmb->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_TOUCH_BET) {
        $bet_parameters->{'barrier'} =
              $fmb->relative_barrier
            ? $fmb->relative_barrier
            : $fmb->absolute_barrier;
    } elsif ($fmb->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_SPREAD_BET) {
        $bet_parameters->{$_} = $fmb->$_ for qw(amount_per_point stop_type stop_loss stop_profit spread);
    }

    return $bet_parameters;
}

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

    if (not exists $AVAILABLE_CONTRACTS{$test_bet_name} or $shortcode =~ /_\d+H\d+/) {
        return {
            bet_type   => 'Invalid',    # it doesn't matter what it is if it is a legacy
            underlying => 'config',
            currency   => $currency,
        };
    }

    if ($shortcode =~ /^(SPREADU|SPREADD)_([\w\d]+)_(\d*.?\d*)_(\d+)_(\d*.?\d*)_(\d*.?\d*)_(DOLLAR|POINT)/) {
        return {
            shortcode        => $shortcode,
            bet_type         => $1,
            underlying       => BOM::Market::Underlying->new($2),
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
        croak 'Unknown shortcode ' . $shortcode;
    }

    my $underlying = BOM::Market::Underlying->new($underlying_symbol);
    if (Date::Utility::is_ddmmmyy($date_expiry)) {
        my $calendar = $underlying->calendar;
        $date_expiry = Date::Utility->new($date_expiry);
        if (my $closing = $calendar->closing_on($date_expiry)) {
            $date_expiry = $closing->epoch;
        } else {
            my $regular_close = $calendar->closing_on($calendar->regular_trading_day_after($date_expiry));
            $date_expiry = Date::Utility->new($date_expiry->date_yyyymmdd . ' ' . $regular_close->time_hhmmss);
        }
    }
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
        ($forward_start) ? (is_forward_starting => $forward_start) : (),
        %barriers,
    };

    return $bet_parameters;
}

1;
