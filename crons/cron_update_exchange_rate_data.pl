#!/usr/bin/perl
package main;

use strict;
use warnings;

use include_common_modules;
use BOM::Platform::Sysinit ();
use BOM::Platform::Model::ExchangeRate;
use BOM::Platform::Data::Persistence::ConnectionBuilder;

BOM::Utility::Log4perl::init_log4perl_console;
BOM::Platform::Sysinit::init();
my $logger = get_logger;

my @all_currencies = ('USD', 'GBP', 'EUR', 'AUD', 'JPY');

my $update_time = BOM::Utility::Date->new($ARGV[0] || time());

$logger->debug('Update exchange rate for date [' . $update_time->db_timestamp . ']');

my $dbs;
foreach my $broker ('FOG') {
    my $operation = ($broker eq 'FOG') ? 'write_collector' : 'write';

    $dbs->{$broker} = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
            broker_code => $broker,
            operation   => $operation,
        })->db;
}

CURRENCY:
foreach my $currency (@all_currencies) {
    next CURRENCY if $currency eq 'USD';

    my $symbol = 'frx' . $currency . 'USD';
    $logger->debug('Symbol [' . $symbol . ']');

    my $underlying = BOM::Market::Underlying->new($symbol);
    my $price      = $underlying->spot;

    if (!$price) {
        $logger->info('There is no price for symbol [' . $symbol . '] on date [' . $update_time->db_timestamp . ']');
        next;
    }

    $logger->debug('Price for symbol [' . $symbol . '] on date [' . $update_time->db_timestamp . '] is [' . $price . ']');

    # Insert exchange rate
    foreach my $broker (keys %{$dbs}) {
        my $exchange_rate = BOM::Platform::Model::ExchangeRate->new({
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
            my $log = "Unsuccess to update; [$broker] ERROR: [" . $@ . "]";
            $logger->logcarp($log);
        }
    }
    $logger->debug('Exchange rate updated successfully for symbol [' . $symbol . '] on date [' . $update_time->db_timestamp . ']');
}
