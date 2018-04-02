=head1 NAME

BOM::RPC::v3::Feeds

=head1 DESCRIPTION

This package is a collection of utility functions that implement websocket API calls related to feeds.

=cut

package BOM::RPC::v3::Feeds;

use BOM::RPC::Registry '-dsl';
use Postgres::FeedDB::CurrencyConverter qw(in_USD);
use Scalar::Util qw(looks_like_number);
use Try::Tiny;

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
    my $base = "USD";
    # Get available currencies
    my $supported_currencies = BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies('costarica');

    my %rates_map;
    foreach my $currency (@$supported_currencies) {
            next if $currency eq $base;
            try{
                my $ex_rate = in_USD(1, $currency);
                $rates_map{$currency} = 1/$ex_rate if looks_like_number($ex_rate) && $ex_rate != 0;
            };
    }
    
    return {
        date => time,
        base => $base,
        rates => \%rates_map,
    };
};

1;



