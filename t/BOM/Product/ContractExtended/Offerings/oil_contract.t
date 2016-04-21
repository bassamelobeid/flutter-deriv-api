#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 8;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Data::Tick;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Date::Utility;
use BOM::Market::Underlying;

my @date_start = ('2016-02-15 08:15:00', '2016-02-15 08:30:00', '2016-02-16 08:30:00');
my @duration   = ('20m',                 '24h',                 '2m');
my @error      = (
    qr/Trading is not available from 08:15:00 to 08:25:00/,
    qr/Contracts on Oil\/USD with durations under 24 hours must expire on the same trading day./,
    qr/Trading is not offered for this duration./,
);
my $u     = BOM::Market::Underlying->new('frxBROUSD');
my $count = 0;
foreach my $ds (@date_start) {
    $ds = Date::Utility->new($ds);
    my $tick = BOM::Market::Data::Tick->new({
        symbol => $u,
        quote  => 100,
        epoch  => $ds->epoch,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => Date::Utility->new($ds->epoch - 600),
        }) for qw (USD BRO);

    my $pp = {
        bet_type     => 'CALL',
        underlying   => $u,
        barrier      => 'S0P',
        date_start   => $ds,
        date_pricing => Date::Utility->new($ds->epoch - 600),
        currency     => 'USD',
        payout       => 100,
        duration     => $duration[$count],
        current_tick => $tick,
    };
    my $c = produce_contract($pp);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message_to_client, $error[$count], "underlying $u->symbol, error is as expected [$error[$count]]";
    $count++;
}

my @date_start_2 = ('2016-02-15 08:25:01', '2016-02-15 08:30:00');
my @duration_2   = ('20m',                 '10h58m59s');
my $count_2      = 0;
foreach my $ds_2 (@date_start_2) {
    $ds_2 = Date::Utility->new($ds_2);
    my $tick_2 = BOM::Market::Data::Tick->new({
        symbol => $u,
        quote  => 100,
        epoch  => $ds_2->epoch,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $ds_2,
        }) for qw (USD BRO);

    my $pp_2 = {
        bet_type     => 'CALL',
        underlying   => $u,
        barrier      => 'S0P',
        date_start   => $ds_2,
        date_pricing => Date::Utility->new($ds_2->epoch - 600),
        currency     => 'USD',
        payout       => 100,
        duration     => $duration_2[$count_2],
        current_tick => $tick_2,
    };
    my $c_2 = produce_contract($pp_2);
    ok $c_2->is_valid_to_buy, 'valid to buy';

    $count_2++;
}
