package BOM::RPC::v3::Contract;

use strict;
use warnings;
no indirect;

use List::MoreUtils qw(none);
use List::Util      qw(any);
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
use Finance::Underlying;
use Syntax::Keyword::Try;

=head2 is_invalid_symbol

This checks if a know about the existence of the given symbol. A symbol is valid if it is defined in
the configuration file. A symbol can be disabled by still valid.

Returns symbol as invalid if
- symbol is undef
- symbol is suspended in backoffice
- symbol is not defined in Finance::Underlying

=cut

sub is_invalid_symbol {
    my $symbol = shift;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidSymbol',
            message_to_client => localize("Symbol [_1] is invalid.", $symbol),
        }) unless $symbol;

    my $error;
    return $error if ($error = is_symbol_suspended($symbol));
    return $error if ($error = is_symbol_offered($symbol));

}

=head2 is_symbol_suspended

This checks if a given symbol is suspended. A symbol is suspended if it is defined in Back Office dynamic configuration tool

=cut

sub is_symbol_suspended {
    my $symbol = shift;

    my $suspended_offerings = BOM::Config::Runtime->instance->get_offerings_config->{suspend_underlying_symbols};

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidSymbol',
            message_to_client => localize("Symbol [_1] is invalid.", $symbol),
        }) if any { $symbol eq $_ } @$suspended_offerings;

}

=head2 is_symbol_offered

This checks if a given symbol is offered.
Every synthetic indices are offered by default, since they are generated by the system but not necessarily offered in BO/Multiplier business but offered in CFD side of business.

We don't want to expose ticks/ticks_history API to too much symbols, so we only allow
- every synthetic indices
- financial/crypto pairs that is offered on BO/Multiplier

=cut

sub is_symbol_offered {
    my $symbol = shift;

    try {
        my $ul = Finance::Underlying->by_symbol($symbol);
        return undef if $ul->is_generated;
    } catch {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidSymbol',
            message_to_client => localize("Symbol [_1] is invalid.", $symbol),
        });
    }

    my $config        = BOM::Config::Runtime->instance->get_offerings_config;
    my $offerings_obj = LandingCompany::Registry->get_default_company()->basic_offerings($config);
    unless ($symbol && $offerings_obj->offerings->{$symbol}) {

        my @offerings = keys %{$offerings_obj->offerings};
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
    return undef unless grep { exists $contract_parameters->{$_} } qw(barrier barrier2 low_barrier high_barrier);

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
