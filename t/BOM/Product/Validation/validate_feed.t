#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings qw(warning);
use Test::Warn;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;

use BOM::Config::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Test::MockModule;
use Postgres::FeedDB::Spot;

my $now   = Date::Utility->new('2016-03-15 01:00:00');
my $delay = $now->minus_time_interval('901s');
note('Forex maximum allowed feed delay is 5 minutes');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD JPY JPY-USD NOK NOK-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'DJI',
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(frxUSDJPY frxUSDNOK);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'DJI',
        recorded_date => $now
    });
my $bet_params = {
    underlying   => 'frxUSDJPY',
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 100,
    date_start   => $now,
    date_pricing => $now,
    duration     => '3d',
    barrier      => 'S0P',

};

my $fake_tick = Postgres::FeedDB::Spot::Tick->new({
    underlying => 'frxUSDJPY',
    epoch      => 1,
    quote      => 100,
});

my $old_tick;

subtest 'open contracts - missing current tick & quote too old' => sub {
    warning_like {
        $bet_params->{_basis_tick}  = $fake_tick;    # basis tick need to be present
        $bet_params->{date_pricing} = $now;
        my $c = produce_contract($bet_params);
        ok !$c->is_expired,      'contract not expired';
        ok !$c->is_valid_to_buy, 'not valid to buy';
        like($c->primary_validation_error->{message}, qr/No realtime data/, 'no realtime data message');
        is $c->primary_validation_error->{details}->{field}, 'symbol', 'error detials is not correct';
        $old_tick = Postgres::FeedDB::Spot::Tick->new({
            underlying => 'frxUSDJPY',
            epoch      => $delay->epoch,
            quote      => 100,
        });
        my $tick = Postgres::FeedDB::Spot::Tick->new({
            underlying => 'frxUSDJPY',
            epoch      => $now->epoch,
            quote      => 100
        });
        $bet_params->{current_tick} = $old_tick;
        $c = produce_contract($bet_params);
        ok !$c->is_valid_to_buy, 'not valid to buy';
        like($c->primary_validation_error->{message}, qr/Quote too old/, 'no realtime data message');
        is $c->primary_validation_error->{details}->{field}, 'symbol', 'error detials is not correct';
        $bet_params->{current_tick} = $tick;
        $c = produce_contract($bet_params);
        ok $c->is_valid_to_buy, 'valid to buy';
    }
    qr/No current_tick for/, 'warn';
};

subtest 'expired contracts' => sub {
    $bet_params->{date_pricing} = $now->plus_time_interval('4d');
    $bet_params->{current_tick} = $old_tick;
    $bet_params->{exit_tick}    = $fake_tick;
    my $c = produce_contract($bet_params);
    ok $c->is_expired, 'contract expired';
    ok !$c->_validate_feed, 'no feed error triggered';
};

subtest 'max_feed_delay_seconds' => sub {
    $bet_params->{underlying} = 'frxUSDJPY';
    $bet_params->{duration}   = '7d';
    my $c = produce_contract($bet_params);
    is $c->maximum_feed_delay_seconds, 30, '30 seconds for major pairs';
    $bet_params->{underlying} = 'frxUSDNOK';
    $c = produce_contract($bet_params);
    is $c->maximum_feed_delay_seconds, 30, '30 seconds for minor pairs';
    $bet_params->{underlying} = 'DJI';
    $c = produce_contract($bet_params);
    is $c->maximum_feed_delay_seconds, 300, '5 minutes for index';

    my $now = Date::Utility->new();
    $bet_params->{date_pricing} = $now;
    $bet_params->{date_start}   = $now;
    $bet_params->{underlying}   = 'frxUSDJPY';
    my $mock = Test::MockModule->new('BOM::Product::Contract');
    my $tick = {
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch - 30,
        quote      => 100
    };
    my $pg_tick = Postgres::FeedDB::Spot::Tick->new($tick);
    $mock->mock('current_tick', sub { $pg_tick });
    $c = produce_contract($bet_params);
    ok !$c->is_expired, 'contract is not yet expired';
    SKIP: {
        skip 'no forex feed available over weekend/holiday', 5 unless $c->trading_calendar->is_open_at($c->underlying->exchange, $c->date_pricing);
        ok !$c->_validate_feed, 'no event and feed is 30 seconds delay';
        $tick->{epoch} = $now->epoch - 31;
        $pg_tick = Postgres::FeedDB::Spot::Tick->new($tick);
        ok $c->_validate_feed, 'invalid if feed is more than 30 seconds delay';
        my $event = {
            event_name   => 'test',
            vol_change   => 0.5,
            release_date => $now->epoch
        };
        $mock->mock('_applicable_economic_events', sub { [$event] });
        $tick->{epoch} = $now->epoch - 3;
        $pg_tick = Postgres::FeedDB::Spot::Tick->new($tick);
        ok $c->_validate_feed, 'invalid if feed is more than 15 seconds delay';
        $tick->{epoch} = $now->epoch - 2;
        $pg_tick = Postgres::FeedDB::Spot::Tick->new($tick);
        ok !$c->_validate_feed, 'valid if tick is 2 seconds old if there is a level 5 economic event';
        $bet_params->{date_pricing} = $bet_params->{date_start} = $now->epoch + 1;
        $c = produce_contract($bet_params);
        ok $c->_validate_feed, 'invalid if feed is more than 2 seconds old if there is a level 5 economic event';
    }
    $tick->{epoch}              = $now->epoch + 1;
    $pg_tick                    = Postgres::FeedDB::Spot::Tick->new($tick);
    $bet_params->{date_pricing} = $bet_params->{date_start} = $now->epoch + 5;
    ok !$c->_validate_feed, 'valid. maximum_feed_delay_seconds is back to 15 seconds once we receives a tick after the level 5 economic event';
};

done_testing();
