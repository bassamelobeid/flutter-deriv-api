
=head1 NAME

BOM::RPC::v3::MarketData

=head1 DESCRIPTION

This package is a collection of utility functions that implement remote procedure calls related to market data.

=cut

package BOM::RPC::v3::MarketData;

use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use Try::Tiny;
use BOM::RPC::Registry '-dsl';
use LandingCompany::Registry;
use Postgres::FeedDB::CurrencyConverter qw(in_USD);
use BOM::Platform::Context qw (localize);
use BOM::RPC::v3::Utility;

use Exporter qw/import/;
our @EXPORT_OK = qw(to_USD, _exchange_rates);

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

# auxiliary function just in order to be able to mock currency conversion
sub to_USD {
    my $val      = shift;
    my $currency = shift;
    return Postgres::FeedDB::CurrencyConverter::in_USD(1, $currency);
}

sub _exchange_rates {
    my $base = "USD";
    my %rates_hash;
    try {
        # Get available currencies
        my @all_currencies = LandingCompany::Registry->new()->all_currencies;
        #Fill a hash of exchange rates
        foreach my $currency (@all_currencies) {
            next if $currency eq $base;
            try {
                my $ex_rate = to_USD(1, $currency);
                $rates_hash{$currency} = 1 / $ex_rate if looks_like_number($ex_rate) && $ex_rate != 0;
            };
        }
    }
    catch {
        %rates_hash = ();
    }
    return BOM::RPC::v3::Utility::create_error({
            code              => 'NoExRates',
            message_to_client => localize('Not Found'),
        }) unless scalar(keys %rates_hash);

    return {
        date  => time,
        base  => $base,
        rates => \%rates_hash,
    };
}

rpc exchange_rates => \&_exchange_rates;

1;

