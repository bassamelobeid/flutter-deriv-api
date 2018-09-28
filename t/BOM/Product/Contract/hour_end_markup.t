#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);
use Test::MockModule;
use BOM::Config::Runtime;

BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
    '{"yyy": {"market": "forex", "barrier_category": "euro_atm", "commission": "0.05", "name": "test commission", "updated_on": "xxx date", "updated_by": "xxyy"}}'
);

my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 110 + 0.005 * $_} } (0 .. 80)];
    });
initialize_realtime_ticks_db();
my $now = Date::Utility->new('2018-09-18 13:57:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => $_,
    }) for qw( USD JPY JPY-USD );
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch - 57*60,
    quote      => 110     
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch - 50*60,
    quote      => 98
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch ,
    quote      => 100,
});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});

my $args = {
    bet_type     => 'CALL',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '10m',
    currency     => 'USD',
    payout       => 10,
    barrier      => 'S0P',
};

subtest 'hour_end_markup' => sub {
    lives_ok {
        my $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.62, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.0, 'no end hour markup';

        $args->{date_start} = Date::Utility->new('2018-09-18 15:57:00');
        $args->{date_pricing} = Date::Utility->new('2018-09-18 15:57:00');
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.62, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.1, 'correct end hour markup';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'), '==', 1, 'correct X1';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('adjustment_multiplier'), '==', 0.1, 'correct adjustment multiplier';
        $args->{bet_type} = 'PUT';
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.38, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.0, 'correct end hour markup';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'), '==', -1, 'correct X1';

        $args->{bet_type} = 'CALL';
        $args->{date_start} = Date::Utility->new('2018-09-19 00:57:00');
        $args->{date_pricing} = Date::Utility->new('2018-09-19 00:57:00');
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.62, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.1, 'correct end hour markup';
        # Monday morning
        $args->{date_start} = Date::Utility->new('2018-09-24 00:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-09-24 00:01:00');
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.62, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.0, 'no end hour markup';

        # Summer on AU 
        $args->{date_start} = Date::Utility->new('2018-10-16 01:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 01:01:00');
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 7.12, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.15, 'correct end hour markup';


        # Winter on EU
        $args->{date_start} = Date::Utility->new('2018-11-16 16:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 16:01:00');
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 7.12, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.15, 'correct end hour markup';

};
};


