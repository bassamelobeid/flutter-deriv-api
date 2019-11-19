package BOM::Test::Helper::ExchangeRates;

use strict;
use warnings;
use BOM::Config::RedisReplicated;

use LandingCompany::Registry;
use Exporter qw( import );
our @EXPORT_OK = qw( populate_exchange_rates populate_exchange_rates_db);
# Subroutine for populating exchange rates for tests
my %all_currencies_rates =
    map { $_ => 1 } LandingCompany::Registry::all_currencies();
my $rates = \%all_currencies_rates;

sub populate_exchange_rates {
    my $local_rates = shift || $rates;
    $local_rates = {%$rates, %$local_rates};
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
    $local_rates = {%$rates, %$local_rates};

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
