#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::FailWarnings;
use Try::Tiny;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Test::MockModule;
use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
    });
initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => $_,
    }) for qw( USD JPY JPY-USD AUD AUD-JPY);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for ('frxUSDJPY', 'frxAUDJPY');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'JPY',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        type          => 'implied',
        implied_from  => 'USD',
        recorded_date => $now,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        rates  => {
            1   => 3,
            2   => 2,
            7   => 1,
            32  => 1.25,
            62  => 1.2,
            92  => 1.18,
            186 => 1.1,
            365 => 1.13,
        },
        type          => 'market',
        recorded_date => $now,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});

subtest 'config' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch - 1, 'frxUSDJPY'], [100.10, $now->epoch + 1, 'frxUSDJPY']);
    my $c = produce_contract({
        bet_type     => 'CALLSPREAD',
        underlying   => 'frxUSDJPY',
        duration     => '2h',
        high_barrier => 'S100P',
        low_barrier  => 'S-100P',
        currency     => 'USD',
        payout       => 100,
    });
    is $c->longcode->[0], 'Win up to [_7] [_6] if [_1]\'s exit tick is between [_5] and [_4] at [_3] after [_2].';
    is $c->longcode->[2][0], 'contract start time';
    is $c->longcode->[3]->{value}, 7200;
    ok !$c->is_binary, 'non-binary';
    ok $c->two_barriers,       'two barriers';
    is $c->pricing_code,       'CALLSPREAD', 'pricing code is CALLSPREAD';
    is $c->display_name,       'Call Spread', 'display name is Call Spread';
    is $c->category_code,      'callputspread', 'category code is callputspread';
    is $c->payout_type,        'non-binary', 'payout type is non-binary';
    is $c->payouttime,         'end', 'payout time is end';
    is $c->ask_price,          56.24, 'correct ask price';
    is $c->bid_price,          52.57, 'correct bid price';
    isa_ok $c->pricing_engine, 'Pricing::Engine::Callputspread';
    isa_ok $c->high_barrier,   'BOM::Product::Contract::Strike';
    isa_ok $c->low_barrier,    'BOM::Product::Contract::Strike';
};

done_testing();
