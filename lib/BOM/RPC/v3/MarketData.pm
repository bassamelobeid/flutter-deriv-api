package BOM::RPC::v3::MarketData;

=head1 NAME

BOM::RPC::v3::MarketData

=head1 DESCRIPTION

This package is a collection of utility functions that implement remote procedure calls related to market data.

=cut

use strict;
use warnings;

use Format::Util::Numbers qw(formatnumber);
use Scalar::Util qw(looks_like_number);
use List::Util qw(any);

use LandingCompany::Registry;
use ExchangeRates::CurrencyConverter qw(convert_currency);

use BOM::RPC::Registry '-dsl';
use BOM::Platform::Context qw (localize);
use BOM::RPC::v3::Utility;

=head2 exchange_rates

    $exchg_rages = exchange_rates()

This function returns the rates of exchanging from all supported currencies into a base currency. 
The argument is optional and consists of a hash with a single key that represents base currency (default value is USD):
    =item * base_currency (Base currency)

The return value is an anonymous hash contains the following items:


=over 4

=item * base (Base currency)

=item * date (The epoch time of data retrieval as an integer number)

=item * rates (A hash containing currency=>rate pairs)

=back

=cut

rpc exchange_rates => sub {
    my $params        = shift;
    my $base_currency = $params->{args}->{base_currency};

    my @all_currencies = LandingCompany::Registry->new()->all_currencies;
    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidCurrency',
            message_to_client => localize('Invalid currency.'),
        }) unless (any { $_ eq $base_currency } @all_currencies);

    my %rates_hash;
    foreach my $target (@all_currencies) {
        next if $target eq $base_currency;
        ## no critic (RequireCheckingReturnValueOfEval)
        eval { $rates_hash{$target} = formatnumber('amount', $target, convert_currency(1, $base_currency, $target)); };
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

1;

