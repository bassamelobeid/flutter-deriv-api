#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 6;
use Test::Warnings;
use Test::Exception;
use Date::Utility;

use Format::Util::Numbers qw/roundcommon/;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);
use Test::MockModule;
use BOM::Config::Runtime;
use Math::Util::CalculatedValue::Validatable;
use Pricing::Engine::Markup::IntradayMeanReversionMarkup;

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
    quote      => 110
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

subtest 'hour_end_markup_start_now_contract' => sub {
    lives_ok {
        my $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.9, 'correct ask price';
        ok !$c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), 'no end hour markup';

        $args->{date_start}   = Date::Utility->new('2018-09-18 15:57:00');
        $args->{date_pricing} = Date::Utility->new('2018-09-18 15:57:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'),     '==', 0.1, 'correct end hour markup';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'),                  '==', 1,   'correct X1';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('eoh_base_adjustment'), '==', 0.1, 'correct adjustment multiplier';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_discount'),   '==', 0,   'no discount';
        $args->{bet_type} = 'PUT';
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.0, 'correct end hour markup';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'),              '==', 1,   'correct X1';
        $args->{bet_type}     = 'CALL';
        $args->{date_start}   = Date::Utility->new('2018-09-19 00:57:00');
        $args->{date_pricing} = Date::Utility->new('2018-09-19 00:57:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.1, 'Maximum end hour markup is charged';
        # Monday morning
        $args->{date_start}   = Date::Utility->new('2018-09-24 00:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-09-24 00:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';

        # Summer on AU
        $args->{date_start}   = Date::Utility->new('2018-10-16 01:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 01:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.1, 'Maximum end hour markup is charged';

        $args->{date_start}   = Date::Utility->new('2018-10-16 01:06:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 01:06:00');
        $c                    = produce_contract($args);
        is($c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), undef, 'No hour end markup charged for minute > 5');

        # Winter on EU
        $args->{date_start}   = Date::Utility->new('2018-11-16 16:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 16:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.92, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), undef, 'No hour end markup as London Fix markup is applied');

    };
};

subtest 'hour_end_markup_extra_test_after_logic_change' => sub {
    lives_ok {

        # Summer on AU , hour other than 7 or 19
        $args->{date_start}   = Date::Utility->new('2018-10-16 01:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 01:01:00');
        my $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.1, 'Maximum end hour markup is charged';

        $args->{date_start}   = Date::Utility->new('2018-10-16 18:49:59');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 18:49:59');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.9, 'correct ask price';

        #Summer on AU, date start is between 18:50 and 19:00
        $args->{date_start}   = Date::Utility->new('2018-10-16 18:50:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 18:50:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.9, 'correct ask price';
        cmp_ok roundcommon(0.00001,$c->pricing_engine->risk_markup->peek_amount('mean_reversion_markup')), '==', 0.03999, 'Mean reversion markup is charged';

        $args->{date_start}   = Date::Utility->new('2018-10-16 18:55:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 18:55:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.93, 'correct ask price';
        cmp_ok roundcommon(0.00001, $c->pricing_engine->risk_markup->peek_amount('hour_end_markup')), '==', 0.14286, 'Maximum end hour markup is charged';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'),                  '==', 1,   'correct X1';

        $args->{date_start}   = Date::Utility->new('2018-10-16 18:57:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 18:57:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 7.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.2, 'Maximum end hour markup is charged';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'),                  '==', 1,   'correct X1';

        $args->{date_start}   = Date::Utility->new('2018-10-16 19:00:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 19:00:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 7.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.2, 'Maximum end hour markup is charged';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'),                  '==', 1,   'correct X1';

        # Summer on AU , hour equal 7 or 19
        $args->{date_start}   = Date::Utility->new('2018-10-16 19:02:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 19:02:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 7.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.2, 'Maximum end hour markup is charged';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'),                  '==', 1,   'correct X1';

        $args->{duration}     = '30m';
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 7.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.2, 'Maximum end hour markup is charged';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'),                  '==', 1,   'correct X1';

        $args->{duration}     = '40m';
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.83, 'correct ask price';
        cmp_ok roundcommon(0.00001, $c->pricing_engine->risk_markup->peek_amount('hour_end_markup')), '==', 0.13333, 'end hour markup is charged';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'),                  '==', 1,   'correct X1';

        $args->{duration}     = '50m';
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.16, 'correct ask price';
        cmp_ok roundcommon(0.00001, $c->pricing_engine->risk_markup->peek_amount('hour_end_markup')), '==', 0.06667, 'hour end  markup is charged';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'),                  '==', 1,   'correct X1';

        $args->{duration}     = '60m';
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.9, 'correct ask price';
        cmp_ok roundcommon(0.00001, $c->pricing_engine->risk_markup->peek_amount('mean_reversion_markup')), '==', 0.03997, 'Mean rev markup is charged';
        

        $args->{duration}     = '70m';
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.9, 'correct ask price';
        
        

        $args->{duration}     = '10m';
        $args->{date_start}   = Date::Utility->new('2018-10-16 19:03:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 19:03:00'); 
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.83, 'correct ask price';
        cmp_ok roundcommon(0.00001, $c->pricing_engine->risk_markup->peek_amount('hour_end_markup')), '==', 0.13333, 'Maximum end hour markup is charged';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('X1'),                  '==', 1,   'correct X1';

        # Summer on AU , date start between 19:01 to 19:05
        $args->{date_start}   = Date::Utility->new('2018-10-16 19:05:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 19:05:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.9, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('mean_reversion_markup'), '==', 0.0399850462270067, 'Maximum end hour markup is charged';

        $args->{date_start}   = Date::Utility->new('2018-10-16 19:05:01');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 19:05:01');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.9, 'correct ask price';

        #duration 30m
        $args->{duration} = '30m';
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.9, 'correct ask price';
        cmp_ok roundcommon(0.00001, $c->pricing_engine->risk_markup->peek_amount('mean_reversion_markup')), '==', 0.03998, 'Mean reversion markup is charged';

        #some more
        $args->{duration} = '70m';
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.9, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), undef, 'Hour end markup applies only to contract duration <= 30m');

        # Winter on EU
        $args->{duration}     = '10m';
        $args->{date_start}   = Date::Utility->new('2018-11-16 16:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 16:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.92, 'correct ask price';
        is($c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), undef, 'No hour end markup as London Fix markup is applied');

        # Winter on EU, hour equal 8 or 20
        $args->{date_start}   = Date::Utility->new('2018-11-16 20:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 20:01:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 7.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.2, 'Maximum end hour markup is charged';

        #duration 30m
        $args->{duration} = '30m';
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 7.5, 'correct ask price';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('hour_end_markup'), '==', 0.2, 'Maximum end hour markup is charged';

        #some more
        $args->{duration} = '70m';
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.89, 'correct ask price';
        
    };
};

subtest 'hour_end_markup_forward_starting_contract' => sub {
    $args->{date_start}   = $now->plus_time_interval('20m');
    $args->{date_pricing} = $now->plus_time_interval('10m');
    $args->{duration}     = '10m';
    lives_ok {
        my $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->debug_information->{risk_markup}, undef, 'No hour end markup for forward starting contract starts at 14GMT');
        $args->{date_start}   = Date::Utility->new('2018-09-18 14:57:00');
        $args->{date_pricing} = Date::Utility->new('2018-09-18 14:43:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.5, 'correct ask price';
        is($c->debug_information->{risk_markup}->{parameters}{hour_end_markup}, 0.1, '10% markup for 15GMT during summer');
        $args->{bet_type} = 'PUT';
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->debug_information->{risk_markup}->{parameters}{hour_end_markup}, 0, 'No hour end markup for opposite contract at 15GMT');
        $args->{bet_type}     = 'CALL';
        $args->{date_start}   = Date::Utility->new('2018-09-19 00:57:00');
        $args->{date_pricing} = Date::Utility->new('2018-09-19 00:47:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->debug_information->{risk_markup}->{parameters}{hour_end_markup}, 0,
            'No hour end markup for forward starting contract starts at 00GMT');

        # Monday morning
        $args->{date_start}   = Date::Utility->new('2018-09-24 00:02:00');
        $args->{date_pricing} = Date::Utility->new('2018-09-21 20:40:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->debug_information->{risk_markup}, undef, 'No hour end markup for forward starting contract starts at 00GMT');

        # Summer on AU
        $args->{date_start}   = Date::Utility->new('2018-10-16 12:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-10-16 11:50:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->debug_information->{risk_markup}->{parameters}{hour_end_markup}, 0, 'No hour end markup for opposite contract at 12GMT');

        # Winter on EU
        $args->{date_start}   = Date::Utility->new('2018-11-16 16:01:00');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 14:50:00');
        $c                    = produce_contract($args);
        cmp_ok $c->ask_price, '==', 5.5, 'correct ask price';
        is($c->debug_information->{risk_markup}, undef, 'No hour end contract for forward starting starts at 16GMT but bought at 14GMT');
        $args->{date_pricing} = Date::Utility->new('2018-11-16 15:50:00');
        $c = produce_contract($args);
        cmp_ok $c->ask_price, '==', 6.5, 'correct ask price';
        is($c->debug_information->{risk_markup}->{parameters}{hour_end_markup}, 0.1, '10% markup for 16GMT during winter');

    };
};

my $discount_date = Date::Utility->new('2018-12-06 16:00:00');
my $tick          = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxAUDJPY',
    epoch      => $discount_date->epoch,
    quote      => 110
});
subtest 'test discount for current spot closer to previous low' => sub {
    my $mocked = Test::MockModule->new('Pricing::Engine::Markup::HourEndBase');
    $mocked->mock(
        '_x1',
        sub {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'X1',
                description => 'test',
                set_by      => __PACKAGE__,
                base_amount => 0.6,
            });
        });

    my $args = {
        bet_type     => 'CALL',
        underlying   => 'frxAUDJPY',
        date_start   => $discount_date,
        date_pricing => $discount_date,
        duration     => '10m',
        currency     => 'AUD',
        payout       => 10,
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $c = produce_contract($args);
    is $c->pricing_engine->risk_markup->peek_amount('hour_end_discount'), undef, 'no discount for CALL at X1=0.6';
    $args->{bet_type} = 'PUT';
    $c = produce_contract($args);
    is $c->pricing_engine->risk_markup->peek_amount('hour_end_discount'), undef, 'no discount for PUT at X1=0.6';
    $mocked->mock(
        '_x1',
        sub {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'X1',
                description => 'test',
                set_by      => __PACKAGE__,
                base_amount => 0.4,
            });
        });
    $c = produce_contract($args);
    is $c->pricing_engine->risk_markup->peek_amount('hour_end_discount'), undef, 'no discount for PUT at X1=0.4';
};

subtest 'test discount for current spot closer to previous high' => sub {
    my $mocked = Test::MockModule->new('Pricing::Engine::Markup::HourEndBase');

    $mocked->mock(
        '_x1',
        sub {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'X1',
                description => 'test',
                set_by      => __PACKAGE__,
                base_amount => -0.6,
            });
        });

    my $mocked_london = Test::MockModule->new('Pricing::Engine::Markup::LondonFix');

    $mocked_london->mock('apply_london_fix', sub { return 0 });
    my $args = {
        bet_type     => 'PUT',
        underlying   => 'frxAUDJPY',
        date_start   => $discount_date,
        date_pricing => $discount_date,
        duration     => '10m',
        currency     => 'AUD',
        payout       => 10,
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $c = produce_contract($args);
    is $c->pricing_engine->risk_markup->peek_amount('hour_end_discount'), 0, 'no discount for PUT at X1=-0.6';
    $args->{bet_type} = 'CALL';
    $c = produce_contract($args);

    # since we have changed the way hour end markup was applied (now we will take the higher of hour_end_markup or mean_reversion_markup),
    # mocking mean_reversion_markup for the validity of the test.

    my $mrm = Test::MockModule->new('Pricing::Engine::Markup::IntradayMeanReversionMarkup');
    $mrm->mock(
        'markup',
        sub {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'intraday_mean_reversion_markup',
                description => 'test',
                set_by      => __PACKAGE__,
                base_amount => -0.2,
            });
        });

    is $c->pricing_engine->risk_markup->peek_amount('hour_end_discount'), -0.01, '0.01 discount for CALL at X1=-0.6';
    $mocked->mock(
        '_x1',
        sub {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'X1',
                description => 'test',
                set_by      => __PACKAGE__,
                base_amount => -0.4,
            });
        });
    $c = produce_contract($args);
    is $c->pricing_engine->risk_markup->peek_amount('hour_end_discount'), 0, 'no discount for CALL at X1=-0.4';
};

