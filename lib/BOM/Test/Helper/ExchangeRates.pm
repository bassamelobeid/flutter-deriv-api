package BOM::Test::Helper::ExchangeRates;

use strict;
use warnings;
use BOM::Config::RedisReplicated;

use Exporter qw( import );
our @EXPORT_OK = qw( populate_exchange_rates );

# Subroutine for populating exchange rates for tests
sub populate_exchange_rates {

    my $rates = shift
        || {
        USD => 1,
        EUR => 1.1888,
        GBP => 1.3333,
        JPY => 0.0089,
        BTC => 5500,
        BCH => 320,
        LTC => 50,
        DAI => 1,
        };

    my $redis = BOM::Config::RedisReplicated::redis_exchangerates_write();
    $redis->hmset(
        'exchange_rates::' . $_ . '_USD',
        quote => $rates->{$_},
        epoch => time
    ) for keys %$rates;

    return;
}

1;
