package BOM::RPC::v3::MarketData;

=head1 NAME

BOM::RPC::v3::MarketData

=head1 DESCRIPTION

This package is a collection of utility functions that implement remote procedure calls related to market data.

=cut

use strict;
use warnings;

use List::Util qw(uniq);
use List::Util qw(any);
use Date::Utility;
use BOM::Config::Chronicle;

use LandingCompany::Registry;
use ExchangeRates::CurrencyConverter qw(convert_currency);
use BOM::User::Client;
use BOM::Config::CurrencyConfig;

use BOM::RPC::Registry '-dsl';
use BOM::Platform::Context qw (localize request);
use BOM::RPC::v3::Utility;

use constant {
    EE_LOOKUP_PERIOD => 14,    #14 days in the future, 14 days in the past
};

=head2 exchange_rates

    $exchg_rates = exchange_rates()

This function returns the rates of exchanging from all supported currencies into a base currency.
The argument is optional and consists of a hash with a single key that represents base currency (default value is USD):
    =item * base_currency (Base currency)

The return value is an anonymous hash contains the following items:

=over 4

=item * C<base_currency> (Base currency)

=item * C<date> (The epoch time of data retrieval as an integer number)

=item * C<rates> (A hash containing currency=>rate pairs)

=back

=cut

rpc exchange_rates => sub {
    my $params = shift;

    my $base_currency   = $params->{args}->{base_currency};
    my $target_currency = $params->{args}->{target_currency};
    my $is_subscribed   = $params->{args}->{subscribe};
    my $country_code    = request()->country_code;

    if ($params->{token_details} and $params->{token_details}->{loginid}) {
        my $client = BOM::User::Client->new({loginid => $params->{token_details}->{loginid}});
        # country code should be over-written by client's residence if available
        $country_code = $client->residence if $client and $client->residence;
    }

    # base currency is always the deriv's account currency, so we validate it against landing company's
    # available payout currency
    my $invalid_currency = BOM::Platform::Client::CashierValidation::invalid_currency_error($base_currency);
    return BOM::RPC::v3::Utility::create_error($invalid_currency) if $invalid_currency;

    # if both base and local currencies are available, user wants a specific exchange rate
    my %rates_hash;
    if ($base_currency and $target_currency) {
        ## no critic (RequireCheckingReturnValueOfEval)
        eval { $rates_hash{$target_currency} = convert_currency(1, $base_currency, $target_currency) };
    } elsif ($base_currency && $is_subscribed && !$target_currency) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'MissingRequiredParams',
            message_to_client => localize('Target currency is required.'),
        });
    } else {
        foreach my $currency (uniq(keys %BOM::Config::CurrencyConfig::ALL_CURRENCIES, LandingCompany::Registry::all_currencies())) {
            next if $currency eq $base_currency;
            ## no critic (RequireCheckingReturnValueOfEval)
            eval { $rates_hash{$currency} = convert_currency(1, $base_currency, $currency) };
        }
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => 'ExchangeRatesNotAvailable',
            message_to_client => localize('Exchange rates are not currently available.'),
        }) unless (keys %rates_hash);

    return {
        date          => time,
        base_currency => $base_currency,
        rates         => \%rates_hash,
    };
};

rpc economic_calendar => sub {
    my $params = shift;

    my $now            = Date::Utility->new();
    my $start_date_arg = $params->{args}->{start_date};
    my $end_date_arg   = $params->{args}->{end_date};
    my $currency       = $params->{args}->{currency};

    my ($start_date, $end_date);
    my $today_start    = $now->truncate_to_day();
    my $today_end      = $today_start->plus_time_interval('23h59m59s');
    my $min_start_date = $today_start->minus_time_interval(EE_LOOKUP_PERIOD . 'd');
    my $max_end_date   = $today_end->plus_time_interval(EE_LOOKUP_PERIOD . 'd');
    $start_date = $today_start unless defined $start_date_arg;
    $end_date   = $today_end   unless defined $end_date_arg;

    if (defined $start_date_arg) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InputValidationFailed',
                message_to_client => localize("Input validation failed: [_1]", "end_date"),
                details           => {
                    end_date => localize("Please enter end date."),
                },
            }) unless defined $end_date_arg;
        $start_date = Date::Utility->new($start_date_arg);
        return _default_invalid_date_error("start_date", $min_start_date->epoch(), $max_end_date->epoch())
            if $start_date->is_before($min_start_date)
            or $start_date->is_after($max_end_date);
    } else {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InputValidationFailed',
                message_to_client => localize("Input validation failed: [_1]", "start_date"),
                details           => {
                    start_date => localize("Please enter start date."),
                },
            }) if defined $end_date_arg;
    }

    if (defined $end_date_arg) {
        $end_date = Date::Utility->new($end_date_arg);
        return _default_invalid_date_error("end_date", $start_date->epoch(), $max_end_date->epoch())
            if $end_date->is_before($start_date)
            or $end_date->is_after($max_end_date)
            or $end_date->is_before($min_start_date);
    }

    my $economic_calendar = Quant::Framework::EconomicEventCalendar->new({chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader()});
    my $events            = $economic_calendar->get_economic_event_calendar_for_display({
        currency   => $currency,
        start_date => $start_date,
        end_date   => $end_date
    });

    return {'events' => $events};
};

sub _default_invalid_date_error {
    my ($field, $min, $max) = @_;
    return BOM::RPC::v3::Utility::create_error({
            code              => 'InputValidationFailed',
            message_to_client => localize("Input validation failed: [_1]", $field),
            details           => {
                $field => localize("The date you entered is not allowed. Please enter a date between [_1] and [_2].", $min, $max),
            },
        });
}

1;
