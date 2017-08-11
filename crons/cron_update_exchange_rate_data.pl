#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

BEGIN {
    push @INC, "/home/git/regentmarkets/bom-backoffice/lib";
}

use BOM::Backoffice::Sysinit ();
use BOM::Database::Model::ExchangeRate;
use BOM::Database::ClientDB;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::MarketData qw(create_underlying_db);
use Date::Utility;

BOM::Backoffice::Sysinit::init();

my @all_currencies = ('USD', 'GBP', 'EUR', 'AUD', 'JPY', 'BTC', 'LTC', 'ETH');

my $update_time = Date::Utility->new($ARGV[0] || time());

my $dbs;
foreach my $broker ('FOG') {
    my $operation = ($broker eq 'FOG') ? 'collector' : 'write';

    $dbs->{$broker} = BOM::Database::ClientDB->new({
            broker_code => $broker,
            operation   => $operation,
        })->db;
}

CURRENCY:
foreach my $currency (@all_currencies) {
    next CURRENCY if $currency eq 'USD';

    my $symbol = 'frx' . $currency . 'USD';

    my $underlying = create_underlying($symbol);
    my $price      = $underlying->spot;

    next unless $price;

    # Insert exchange rate
    foreach my $broker (keys %{$dbs}) {
        my $exchange_rate = BOM::Database::Model::ExchangeRate->new({
                data_object_params => {
                    source_currency => $currency,
                    target_currency => 'USD',
                    date            => $update_time->db_timestamp,
                },
                db => $dbs->{$broker}});

        eval {
            $exchange_rate->load({'load_params' => {speculative => 1}});
            $exchange_rate->exchange_rate_record->rate($price);

            $exchange_rate->save;
            1;
        } or do {
            warn("Unsuccess to update; [$broker] ERROR: [" . $@ . "]");
            }
    }
}
