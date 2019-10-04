package BOM::Test::Helper::ExchangeRates;

use strict;
use warnings;
use BOM::Config::RedisReplicated;

use Exporter qw( import );
our @EXPORT_OK = qw( populate_exchange_rates populate_exchange_rates_db);

# Subroutine for populating exchange rates for tests
my $rates = {
    USD => 1,
    EUR => 1.1888,
    GBP => 1.3333,
    JPY => 0.0089,
    BTC => 5500,
    BCH => 320,
    LTC => 50,
    ETH => 490,
    UST => 1,
    USB => 1,
    AUD => 1,
    IDK => 1,
};

sub populate_exchange_rates {
    my $local_rates = shift || $rates;
    my $redis = BOM::Config::RedisReplicated::redis_exchangerates_write();
    $redis->hmset(
        'exchange_rates::' . $_ . '_USD',
        quote => $local_rates->{$_},
        epoch => time
    ) for keys %$local_rates;

    return;
}

sub populate_exchange_rates_db {
    my $dbic = shift;
    my $local_rates = shift || $rates;

    $dbic->run(
        fixup => sub {
            my $sth = $_->prepare("INSERT INTO data_collection.exchange_rate (source_currency, target_currency, rate , date) VALUES (?,?,?, now())");
            foreach my $currency_code (keys(%$local_rates)) {
                $sth->execute($currency_code, 'USD', $local_rates->{$currency_code});
            }
        });
    return 1;
}

1;
