package BOM::Test::Helper::ExchangeRates;

use strict;
use warnings;
use Exporter qw( import );
our @EXPORT_OK = qw( populate_exchange_rates );

# Mock exchange rates and populate in redis
sub populate_exchange_rates {
    my $rates = {
        USD => 1,
        EUR => 1.1888,
        GBP => 1.3333,
        JPY => 0.0089,
        BTC => 5500,
        BCH => 320,
        LTC => 50,
    };

    Cache::RedisDB->set('QUOTE', "frx${_}USD", {quote => $rates->{$_}}) for keys %$rates;
}

1;
