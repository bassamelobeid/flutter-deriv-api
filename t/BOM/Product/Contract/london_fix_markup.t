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
use Math::Util::CalculatedValue::Validatable;
use Format::Util::Numbers qw/roundcommon/;

BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
    '{"yyy": {"market": "forex", "barrier_category": "euro_atm", "commission": "0.05", "name": "test commission", "updated_on": "xxx date", "updated_by": "xxyy"}}'
);

my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
    });
initialize_realtime_ticks_db();
my $now = Date::Utility->new('2018-09-18 13:57:00');
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
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch - 57 * 60,
    quote      => 100.3
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch - 50 * 60,
    quote      => 98
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
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

subtest 'london_fix_markup' => sub {
    lives_ok {

        # Summer on AU , hour other than 15
        $args->{date_start}   = Date::Utility->new('2018-10-16 01:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 01:01:00');
        my $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.5, 'correct ask price';

        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'No hour end markup');

        # Summer on AU , hour equal 15
        $args->{duration}     = '3m';
        $args->{date_start}   = Date::Utility->new('2018-10-16 14:58:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 14:58:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.16, 'correct ask price';
        cmp_ok roundcommon(0.001,$c->pricing_engine->risk_markup->peek_amount('london_fix_markup')), '==', 0.087, 'correct london markup';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('trend_following_duration'), '==', 120, 'trend_following_duration';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('trend_reversal_duration'), '==', 60, 'trend_reversal_duration';
        #max_trend_following_multiplier
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('max_trend_following_multiplier'), '==', 0.275, 'max_trend_following_multiplier';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('max_trend_reversal_multiplier'), '==', 0.15, 'max_trend_reversal_multiplier';


        # Winter on EU
        $args->{duration}     = '10m';
        $args->{date_start}   = Date::Utility->new('2018-11-16 16:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 16:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.25, 'correct ask price';
        cmp_ok roundcommon(0.001, $c->pricing_engine->risk_markup->peek_amount('london_fix_markup')), '==', 0.095, 'correct london fix markup';

        # Winter on EU, hour other than 16
        $args->{date_start}   = Date::Utility->new('2018-11-16 20:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 20:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 7.5, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'No hour end markup');

    };
};

