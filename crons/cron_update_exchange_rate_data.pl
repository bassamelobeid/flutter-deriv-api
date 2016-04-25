#!/usr/bin/perl
package main;

use strict;
use warnings;

use BOM::Platform::Sysinit ();
use BOM::Database::Model::ExchangeRate;
use BOM::Database::ClientDB;
use BOM::Market::Underlying;
use BOM::Market::UnderlyingDB;
use Date::Utility;

BOM::Platform::Sysinit::init();

my @all_currencies = ('USD', 'GBP', 'EUR', 'AUD', 'JPY');

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

    my $underlying = BOM::Market::Underlying->new($symbol);
    my $price      = $underlying->spot;

    if (!$price) {
        next;
    }

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
        };
        if ($@) {
            warn("Unsuccess to update; [$broker] ERROR: [" . $@ . "]");
        }
    }
}
