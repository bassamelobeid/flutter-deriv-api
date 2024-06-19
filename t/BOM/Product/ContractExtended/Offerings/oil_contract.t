#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;

use BOM::Product::ContractFactory qw(produce_contract);
use Postgres::FeedDB::Spot::Tick;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Date::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

my @date_start = ('2016-02-15 08:15:00', '2016-02-15 08:30:00');
my @duration   = ('20m',                 '24h');
my @error      = (
    ['Trading is not available from [_1] to [_2].', '08:15:00', '08:25:00'],
    ['Contracts on this market with a duration of under 24 hours must expire on the same trading day.'],
);
my $u     = create_underlying('frxBROUSD');
my $count = 0;

foreach my $ds (@date_start) {
    $ds = Date::Utility->new($ds);
    my $tick = Postgres::FeedDB::Spot::Tick->new({
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

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol       => 'frxBROUSD',
            surface_data => {
                1 => {
                    vol_spread => {50 => 0},
                    smile      => {
                        25 => 0.1,
                        50 => 0.1,
                        75 => 0.1
                    }
                },
                7 => {
                    vol_spread => {50 => 0},
                    smile      => {
                        25 => 0.1,
                        50 => 0.1,
                        75 => 0.1
                    }
                },
            },
            recorded_date => Date::Utility->new($ds->epoch - 600),
        });
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
    is_deeply($c->primary_validation_error->message_to_client, $error[$count]);
    $count++;
}

my @date_start_2 = ('2016-02-15 08:25:01', '2016-02-15 08:30:00');
my @duration_2   = ('20m',                 '10h58m59s');
my $count_2      = 0;
foreach my $ds_2 (@date_start_2) {
    $ds_2 = Date::Utility->new($ds_2);
    my $tick_2 = Postgres::FeedDB::Spot::Tick->new({
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

done_testing();
