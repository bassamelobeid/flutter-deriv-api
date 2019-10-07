#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
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

BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
    '{"yyy": {"market": "forex", "barrier_category": "euro_atm", "commission": "0.05", "name": "test commission", "updated_on": "xxx date", "updated_by": "xxyy"}}'
);

initialize_realtime_ticks_db();
my $now = Date::Utility->new('2019-08-16 17:00:00');
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

my $args = {
    bet_type     => 'CALL',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    currency     => 'USD',
    payout       => 100,
    barrier      => 'S0P',
};

subtest 'rollover_markup_between_17GMT_to_22GMT' => sub {
        $args->{date_pricing} = Date::Utility->new('2019-08-16 17:00:00');
        $args->{date_expiry} = Date::Utility->new('2019-08-16 22:00:00');
        my $c                  = produce_contract($args);
        my $pe                 = $c->pricing_engine;
        my $bs_probability     = $pe->base_probability->base_amount;
        my $risk_markup        = $pe->risk_markup;
        my $rollover_markup    = $risk_markup->peek_amount('rollover_markup');
        my $interest_rate_diff = $risk_markup->peek_amount('interest_rate_difference');
        my $adustment_before   = $risk_markup->peek_amount('adjustment_before');
        my $adustment_after    = $risk_markup->peek_amount('adjustment_after');
        is($c->ask_price,       54.39,                'correct ask price');
        is($rollover_markup,    -0.00541409767718881,   'correct rollover markup');
        is($interest_rate_diff, 0.0108281953543776,   'correct interest rate diff');
        is($adustment_before,   0.027070488385944,    'correct adjustment before');
        is($adustment_after,    -0.040605732578916, 'correct adjustment after');
};


subtest 'rollover_markup_between_20GMT_to_21GMT' => sub {
        $args->{date_start} = Date::Utility->new('2019-08-16 20:10:00');
        $args->{date_pricing} = Date::Utility->new('2019-08-16 20:10:00');
        $args->{date_expiry} = Date::Utility->new('2019-08-16 20:50:00');
        my $c                  = produce_contract($args);
        my $pe                 = $c->pricing_engine;
        my $bs_probability     = $pe->base_probability->base_amount;
        my $risk_markup        = $pe->risk_markup;
        my $rollover_markup    = $risk_markup->peek_amount('rollover_markup');
        my $interest_rate_diff = $risk_markup->peek_amount('interest_rate_difference');
        my $adustment_before   = $risk_markup->peek_amount('adjustment_before');
        my $adustment_after    = $risk_markup->peek_amount('adjustment_after');
        is($c->ask_price,       63.08,                'correct ask price');
        is($rollover_markup,    0.0210038018661902,   'correct rollover markup');
        is($interest_rate_diff, 0.0126022811197141,   'correct interest rate diff');
        is($adustment_before,   0.030630544388194,    'correct adjustment before');
        is($adustment_after,    -0.00962674252200384, 'correct adjustment after');

};

subtest 'rollover_markup_between_20GMT_to_22GMT' => sub {
        $args->{date_start} = Date::Utility->new('2019-08-16 20:50:00');
        $args->{date_pricing} = Date::Utility->new('2019-08-16 20:50:00');
        $args->{date_expiry} = Date::Utility->new('2019-08-16 22:50:00');
        my $c                  = produce_contract($args);
        my $pe                 = $c->pricing_engine;
        my $bs_probability     = $pe->base_probability->base_amount;
        my $risk_markup        = $pe->risk_markup;
        my $rollover_markup    = $risk_markup->peek_amount('rollover_markup');
        my $interest_rate_diff = $risk_markup->peek_amount('interest_rate_difference');
        my $adustment_before   = $risk_markup->peek_amount('adjustment_before');
        my $adustment_after    = $risk_markup->peek_amount('adjustment_after');
        is($c->ask_price,       55.97,                'correct ask price');
        is($rollover_markup,    -0.05,   'correct rollover markup');
        is($interest_rate_diff, 0.0120564085765337,   'correct interest rate diff');
        is($adustment_before,   0.00920975655151876,    'correct adjustment before');
        is($adustment_after,    -0.059863417584872, 'correct adjustment after');
};

subtest 'rollover_markup_between_21GMT_to_23GMT' => sub {
        $args->{date_start} = Date::Utility->new('2019-08-16 21:50:00');
        $args->{date_pricing} = Date::Utility->new('2019-08-16 21:50:00');
        $args->{date_expiry} = Date::Utility->new('2019-08-16 22:50:00');
        my $c                  = produce_contract($args);
        my $pe                 = $c->pricing_engine;
        my $bs_probability     = $pe->base_probability->base_amount;
        my $risk_markup        = $pe->risk_markup;
        my $rollover_markup    = $risk_markup->peek_amount('rollover_markup');
        my $interest_rate_diff = $risk_markup->peek_amount('interest_rate_difference');
        my $adustment_before   = $risk_markup->peek_amount('adjustment_before');
        my $adustment_after    = $risk_markup->peek_amount('adjustment_after');
        is($c->ask_price,       '57.90',                'correct ask price');
        is($rollover_markup,    -0.0207763549731983,   'correct rollover markup');
        is($interest_rate_diff, 0.012465812983919,   'correct interest rate diff');
        is($adustment_before,   0.0411198692177884,    'correct adjustment before');
        is($adustment_after,    -0.0618962241909867, 'correct adjustment after');

        $args->{date_start} = Date::Utility->new('2019-08-16 22:50:00');
        $args->{date_pricing} = Date::Utility->new('2019-08-16 22:50:00');
        $args->{date_expiry} = Date::Utility->new('2019-08-16 23:50:00');
        $c                  = produce_contract($args);
        $pe                 = $c->pricing_engine;
        $bs_probability     = $pe->base_probability->base_amount;
        $risk_markup        = $pe->risk_markup;
        $rollover_markup    = $risk_markup->peek_amount('rollover_markup');
        $interest_rate_diff = $risk_markup->peek_amount('interest_rate_difference');
        $adustment_before   = $risk_markup->peek_amount('adjustment_before');
        $adustment_after    = $risk_markup->peek_amount('adjustment_after');
        is($c->ask_price,       59.97,                'correct ask price');
        is($rollover_markup,    -7.21401214347159e-05,   'correct rollover markup');
        is($interest_rate_diff, 0.012465812983919,   'correct interest rate diff');
        is($adustment_before,   0.0618962241909867,    'correct adjustment before');
        is($adustment_after,    -0.062329064919595, 'correct adjustment after');
};
