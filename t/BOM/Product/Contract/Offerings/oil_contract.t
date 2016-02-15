#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 33;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Data::Tick;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use Date::Utility;
use BOM::Market::Underlying;
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', { symbol => $_ }) for qw (USD BRO);


my @date_start = ('2016-02-15 08:15:00', '2016-02-15 08:30', '2016-02-16 08:30'); 
my @duration = ('20m', '24h', '2m');
my @errors = (
        qr/Trading is available after the first 10 minutes of the session. Try out the Random Indices which are always open./,
        qr/Contracts on Oil/USD with durations under 24 hours must expire on the same trading day./,
        qr/Duration must be between 5 minutes and 1 day./,
    ); 
my $u        = BOM::Market::Underlying->new('frxBROUSD');
foreach my $ds (@date_start) {
   my $count =0;
   my $tick = BOM::Market::Data::Tick->new({
            symbol => $u,
            quote  => 100,
            epoch  => Date::Utility->new($ds)->epoch,
        });

        my $pp = {
            bet_type     => 'CALL',
            underlying   => $u,
            barrier      => 'S0P',
            date_start   => $ds,
            date_pricing => Date::Utility->new($ds->epoch - 3600),
            currency     => 'USD',
            payout       => 100,
            duration     => $duration[$count],
            current_tick => $tick,
        };
        my $c = produce_contract($pp);
        like $c->primary_validation_error->message_to_client, $error[$count], "underlying $u, error is as expected [$error[$count]]";
        $count ++;
}
