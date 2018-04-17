package BOM::RPC::v3::MarketData;

=head1 NAME

BOM::RPC::v3::MarketData

=head1 DESCRIPTION

This package is a collection of utility functions that implement remote procedure calls related to market data.

=cut

use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use Try::Tiny;
use BOM::RPC::Registry '-dsl';
use LandingCompany::Registry;
use BOM::Platform::Context qw (localize);
use BOM::RPC::v3::Utility;
use Postgres::FeedDB::CurrencyConverter qw(in_USD);
use Format::Util::Numbers qw(formatnumber);

=head2 exchange_rates

    $exchg_rages = exchange_rates()

This function returns the rates of exchanging from all supported currencies into a base currency (USD). It Doesn't have any arguments.

The return value is an anonymous hash contains the following items:


=over 4

=item * base (Base currency)

=item * date (The epoch time of data retrieval as an integer number)

=item * rates (A hash containing currency=>rate pairs)

=back

=cut

rpc exchange_rates => sub {
    my $params = shift;
    my $base   = $params->{base_currency};
    $base = 'USD' if (not $base);

    my @all_currencies = LandingCompany::Registry->new()->all_currencies;
    if (not grep { $_ eq $base } @all_currencies) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'BaseCurrencyUnavailable',
            message_to_client => localize('Base currency is unavailable.'),
        });
    }
    my $base_to_usd = 0;
    try {
        $base_to_usd = in_USD(1, $base);
    }
    catch {};

    my %rates_hash;
    if (looks_like_number($base_to_usd) && $base_to_usd > 0) {
        foreach my $target (@all_currencies) {
            next if $target eq $base;
            try {
                my $target_to_usd = in_USD(1, $target);
                $rates_hash{$target} = formatnumber('price', $target, $base_to_usd / $target_to_usd)
                    if looks_like_number($target_to_usd) && $target_to_usd > 0;
            }
            catch {};
        }
    }
    if (not %rates_hash) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'ExchangeRatesNotAvailable',
            message_to_client => localize('Exchange rates are not currently available.'),
        });
    }

    return {
        date          => time,
        base_currency => $base,
        rates         => \%rates_hash,
    };
};

1;

