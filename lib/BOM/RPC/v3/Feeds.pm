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
    # Get available currencies
    my $payout_currencies = BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies('costarica');
    
    my %exchange_rates;
    foreach $currency (@$payout_currencies)){
        try{
            if ($currency eq "USD")
                continue;
            $ex_rate = in_USD($currency);
            %exchange_rates[$currency] = 1/$rate if (looks_like_number($ex_rate) && $ex_rate != 0);
        }
    }
    
    return {
        date => time,
        base => "USD",
        rates => \%exchange_rates,
    };
};

1;



