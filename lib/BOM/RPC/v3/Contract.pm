package BOM::RPC::v3::Contract;

use strict;
use warnings;
no indirect;

use Try::Tiny;
use List::MoreUtils qw(none);
use Date::Utility;
use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);

use Quant::Framework;
use LandingCompany::Registry;

use BOM::Config::Chronicle;
use BOM::Config;
use BOM::RPC::v3::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Locale;
use BOM::Config::Runtime;

sub is_invalid_symbol {
    my $symbol = shift;
    my @offerings =
        LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config)
        ->values_for_key('underlying_symbol');
    if (!$symbol || none { $symbol eq $_ } @offerings) {

        # There's going to be a few symbols that are disabled or otherwise not provided
        # for valid reasons, but if we have nothing, or it's a symbol that's very
        # unlikely to be disabled, it'd be nice to know.
        warn "Symbol $symbol not found, our offerings are: " . join(',', @offerings)
            if $symbol and ($symbol =~ /^R_(100|75|50|25|10)$/ or not @offerings);

        return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidSymbol',
            message_to_client => localize("Symbol [_1] invalid.", $symbol),
        });
    }
    return undef;
}

sub is_invalid_license {
    my $ul = shift;

    if ($ul->feed_license ne 'realtime') {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'NoRealtimeQuotes',
            message_to_client => localize("Realtime quotes not available for [_1].", $ul->symbol),
        });
    }

    return undef;
}

sub is_invalid_market_time {
    my $ul = shift;
    unless (Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader())->is_open($ul->exchange)) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'MarketIsClosed',
            message_to_client => localize('This market is presently closed.'),
            details           => {field => 'symbol'},
        });
    }

    return undef;
}

sub validate_underlying {
    my $symbol = shift;

    my $error = is_invalid_symbol($symbol);
    return $error if $error;

    my $ul = create_underlying($symbol);

    $error = is_invalid_license($ul);
    return $error if $error;

    $error = is_invalid_market_time($ul);
    return $error if $error;

    return $ul;
}

# Validate the barrier of the contract, based on the decimal places.
# This is compared with the decimal places of the underlying pipsize.
sub validate_barrier {
    my $contract_parameters = shift;

    return undef if (defined $contract_parameters->{barrier} && $contract_parameters->{barrier} eq 'S0P');
    return undef unless exists $contract_parameters->{barrier} or exists $contract_parameters->{barrier2};

    # Get the number of digits of the underlying pipsize.
    create_underlying($contract_parameters->{underlying})->pip_size =~ /\.([0-9]+)/;
    my $pipsize_decimal_places = length $1;

    my @barrier_keys = grep { /barrier/ } keys %{$contract_parameters};

    # Loop through each barrier key, if any
    foreach my $key (@barrier_keys) {

        # Extract the number of decimal places of the given barrier
        # NOTE: If it is not fractional, it is ignored
        if ($contract_parameters->{$key} =~ /\.([0-9]+)/) {
            my $barrier_decimal_places = length $1;

            # Compare with the number of decimal places from the pipsize
            # If barrier has 5 decimal places and pipsize has 4, this would be rejected due to excessive precision.
            if ($barrier_decimal_places > $pipsize_decimal_places) {
                return BOM::RPC::v3::Utility::create_error({
                    code              => 'BarrierValidationError',
                    message_to_client => localize("Barrier can only be up to [_1] decimal places.", $pipsize_decimal_places),
                });
            }
        }
    }

    return undef;
}
1;
