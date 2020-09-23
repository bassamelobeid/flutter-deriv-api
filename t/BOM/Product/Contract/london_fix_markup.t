#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use Date::Utility;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);
use Test::MockModule;
use BOM::Config::Runtime;
use Math::Util::CalculatedValue::Validatable;
use Pricing::Engine::Markup::IntradayMeanReversionMarkup;
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
    duration     => '3m',
    currency     => 'USD',
    payout       => 10,
    barrier      => 'S0P',
};

subtest 'london_fix_markup' => sub {
    my $mocked = Test::MockModule->new('Pricing::Engine::Markup::IntradayMeanReversionMarkup');
    $mocked->mock(
        'markup',
        sub {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'mean_reversion_markup',
                description => 'Intraday mean reversion markup.',
                set_by      => __PACKAGE__,
                base_amount => 0,
            });
        });
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
        cmp_ok $c->ask_price, '==', 5.86, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), 0.0366025403784438, 'correct london fix markup for CALL');

        $args->{bet_type} = 'PUT';
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.59, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), 0.108771324027147, 'correct london fix markup for PUT');

        $args->{bet_type}     = 'CALL';
        $args->{duration}     = '10m';
        $args->{date_start}   = Date::Utility->new('2018-10-16 15:05:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 15:05:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'no london fix markup for CALL at minute 05');

        $args->{date_start}   = Date::Utility->new('2018-10-16 15:06:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 15:06:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'No london fix markup');

        # Summer 16

        $args->{bet_type}     = 'CALL';
        $args->{duration}     = '10m';
        $args->{date_start}   = Date::Utility->new('2018-10-16 16:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 16:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.5, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'No london fix markup');
        is($c->pricing_engine->risk_markup->peek_amount('hour_end_markup'),   0.1,   'correct hour end markup for CALL');

        # Special case without London Fix markup
        $args->{bet_type}     = 'PUT';
        $args->{duration}     = '1m';
        $args->{date_start}   = Date::Utility->new('2018-10-16 14:59:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 14:59:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'No london fix markup');
        is($c->pricing_engine->risk_markup->peek_amount('hour_end_markup'),   undef, 'No hour end markup');

        # Winter on EU
        $args->{bet_type}     = 'CALL';
        $args->{duration}     = '10m';
        $args->{date_start}   = Date::Utility->new('2018-11-16 16:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 16:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.92, 'correct ask price';
        cmp_ok roundcommon(0.001, $c->pricing_engine->risk_markup->peek_amount('london_fix_markup')), '==', 0.142, 'correct london fix markup';
        cmp_ok roundcommon(0.001, $c->pricing_engine->risk_markup->peek_amount('london_fix_x1')),     '==', 1,     'correct london fix markup';

        $args->{bet_type}     = 'CALL';
        $args->{duration}     = '10m';
        $args->{date_start}   = Date::Utility->new('2018-11-16 16:05:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 16:05:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';

        $args->{date_start}   = Date::Utility->new('2018-11-16 16:06:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 16:06:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'No london fix markup');

        # Special case without London Fix markup

        $args->{bet_type}     = 'CALL';
        $args->{duration}     = '1m';
        $args->{date_start}   = Date::Utility->new('2018-11-16 15:59:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 15:59:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'No london fix markup');
        is($c->pricing_engine->risk_markup->peek_amount('hour_end_markup'),   undef, 'No hour end markup');

        #  When $X1 > 0 which means current spot is at spot_min, so we expect upward movement.
        #  Hence, no markup for PUT.
        $args->{bet_type}     = 'PUT';
        $args->{duration}     = '10m';
        $args->{date_start}   = Date::Utility->new('2018-11-16 16:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 16:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        ok !$c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), 'no london fix markup for PUT';

        # Winter on EU, hour other than 16
        $args->{bet_type}     = 'CALL';
        $args->{date_start}   = Date::Utility->new('2018-11-16 20:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 20:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 7.5, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'No hour end markup');

        # test for different contract interval, Winter EU

        $args->{bet_type}     = 'CALL';
        $args->{duration}     = '25m';
        $args->{date_start}   = Date::Utility->new('2018-11-16 15:50:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 15:50:00');
        $c                    = produce_contract($args);
        cmp_ok roundcommon(0.001, $c->pricing_engine->risk_markup->peek_amount('london_fix_markup')), '==', 0.045, 'correct london fix markup';

        $args->{bet_type}     = 'CALL';
        $args->{duration}     = '25m';
        $args->{date_start}   = Date::Utility->new('2018-11-16 16:06:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 16:06:00');
        $c                    = produce_contract($args);
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'No London Fix markup');
        is($c->pricing_engine->risk_markup->peek_amount('hour_end_markup'),   undef, 'No hour end markup');

        $args->{bet_type}     = 'CALL';
        $args->{duration}     = '3m';
        $args->{date_start}   = Date::Utility->new('2018-11-16 15:50:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 15:50:00');
        $c                    = produce_contract($args);
        is($c->pricing_engine->risk_markup->peek_amount('london_fix_markup'), undef, 'No London Fix markup');
        is($c->pricing_engine->risk_markup->peek_amount('hour_end_markup'),   undef, 'No hour end markup');

        # testing edge case for x1
        my $mocked_c = Test::MockModule->new('BOM::Product::Contract');
        $mocked_c->mock('spot_min_max', sub { return {high => 100, low => 99} });
        $args->{duration}     = '3m';
        $args->{date_start}   = Date::Utility->new('2018-10-16 14:58:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 14:58:00');
        $c                    = produce_contract($args);
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('london_fix_x1'), '==', -1, 'max_trend_reversal_multiplier';
    };
};

