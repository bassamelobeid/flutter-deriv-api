package BOM::Test::FakeCurrencyConverter;

use strict;
use warnings;

use Exporter qw( import );

our @EXPORT_OK = qw(fake_in_usd);

sub fake_in_usd {
    my $price         = shift;
    my $from_currency = shift;

    $from_currency eq 'AUD' and return 0.90 * $price;
    $from_currency eq 'BCH' and return 1200 * $price;
    $from_currency eq 'ETH' and return 500 * $price;
    $from_currency eq 'LTC' and return 120 * $price;
    $from_currency eq 'EUR' and return 1.18 * $price;
    $from_currency eq 'GBP' and return 1.3333 * $price;
    $from_currency eq 'JPY' and return 0.0089 * $price;
    $from_currency eq 'BTC' and return 5500 * $price;
    $from_currency eq 'USD' and return 1 * $price;
    return 0;
}

1;
