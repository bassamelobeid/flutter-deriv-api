#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Config::RedisReplicated;
use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use Test::MockModule;

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
        symbol        => $_,
        recorded_date => $now,
    }) for qw(USD JPY AUD CAD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw (JPY-USD CAD-AUD WLDUSD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        underlying    => create_underlying($_),
        recorded_date => $now
    }) for qw (frxUSDJPY frxAUDCAD R_100 WLDUSD);
my $ct = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch + 1,
    quote      => 100,
});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
my $redis     = BOM::Config::RedisReplicated::redis_write();
my $undec_key = "DECIMATE_frxUSDJPY" . "_31m_FULL";
my $encoder   = Sereal::Encoder->new({
    canonical => 1,
});

my %defaults = (
    symbol => 'frxUSDJPY',
    epoch  => $now->epoch,
    quote  => 100,
    bid    => 100,
    ask    => 100,
    count  => 1,
);
$redis->zadd($undec_key, $defaults{epoch}, $encoder->encode(\%defaults));

$defaults{epoch} = $now->epoch + 1;
$defaults{quote} = 100;
$redis->zadd($undec_key, $defaults{epoch}, $encoder->encode(\%defaults));

$ct = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxAUDCAD',
    epoch      => $now->epoch
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxAUDCAD',
    epoch      => $now->epoch + 1,
    quote      => 100,
});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
$redis     = BOM::Config::RedisReplicated::redis_write();
$undec_key = "DECIMATE_frxAUDCAD" . "_31m_FULL";
$encoder   = Sereal::Encoder->new({
    canonical => 1,
});

%defaults = (
    symbol => 'frxAUDCAD',
    epoch  => $now->epoch,
    quote  => 100,
    bid    => 100,
    ask    => 100,
    count  => 1,
);
$redis->zadd($undec_key, $defaults{epoch}, $encoder->encode(\%defaults));

$defaults{epoch} = $now->epoch + 1;
$defaults{quote} = 100;
$redis->zadd($undec_key, $defaults{epoch}, $encoder->encode(\%defaults));

my $args = {
    bet_type     => 'CALLE',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '10m',
    currency     => 'USD',
    payout       => 10,
    barrier      => 'S0P',
};

subtest 'call variations' => sub {
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Calle';
        is $c->code,            'CALLE';
        is $c->other_side_code, 'PUT';
        ok $c->is_intraday,     'is intraday';
        ok !$c->expiry_daily, 'not expiry daily';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
        isa_ok $c->barrier,        'BOM::Product::Contract::Strike';
        cmp_ok $c->barrier->as_absolute, '==', 76.900, 'correct absolute barrier';
        ok $c->theo_probability;
    }
    'generic';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Calle';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';

        $args->{duration} = '5h1s';
        $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Calle';
        isa_ok $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope';

        $args->{duration}     = '10m';
        $args->{date_pricing} = $now->plus_time_interval('10m');
        $args->{date_start}   = $now->plus_time_interval('20m');
        $c                    = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Calle';
        ok $c->is_forward_starting,     'forward starting';
        isa_ok $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope';

        $args->{date_pricing} = $now;
        $args->{date_start}   = $now;
        $args->{duration}     = '15m';
        $args->{barrier}      = 'S0P';
        $c                    = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Calle';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';

        $args->{duration} = '5h1s';
        $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Calle';
        isa_ok $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope';
    }
    'pricing engine selection';
};

subtest 'shortcodes' => sub {
    lives_ok {
        my $c =
            produce_contract(
            'CALLE_FRXUSDJPY_10_' . $now->plus_time_interval('10m')->epoch . 'F_' . $now->plus_time_interval('20m')->epoch . '_S0P_0', 'USD');
        isa_ok $c, 'BOM::Product::Contract::Calle';
        ok $c->starts_as_forward_starting;
    }
    'builds forward starting calle from shortcode';
    lives_ok {
        my $c = produce_contract('CALLE_FRXUSDJPY_10_' . $now->epoch . '_' . $now->plus_time_interval('20m')->epoch . '_S0P_0', 'USD');
        isa_ok $c, 'BOM::Product::Contract::Calle';
        ok !$c->is_forward_starting;
    }
    'builds spot calle from shortcode';
    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            date_start   => $now,
            date_pricing => $now->minus_time_interval('10m'),
            duration     => '20m',
            barrier      => 'S0P',
            underlying   => 'frxUSDJPY',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });
        isa_ok $c, 'BOM::Product::Contract::Calle';
        my $expected_shortcode = 'CALLE_FRXUSDJPY_10_' . $now->epoch . 'F_' . $now->plus_time_interval('20m')->epoch . '_S0P_0';
        is $c->shortcode, $expected_shortcode, 'shortcode matches';
    }
    'builds shortcode from params for forward starting calle';
    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            date_start   => $now,
            date_pricing => $now,
            duration     => '20m',
            barrier      => 'S0P',
            underlying   => 'frxUSDJPY',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });
        isa_ok $c, 'BOM::Product::Contract::Calle';
        my $expected_shortcode = 'CALLE_FRXUSDJPY_10_' . $now->epoch . '_' . $now->plus_time_interval('20m')->epoch . '_S0P_0';
        is $c->shortcode, $expected_shortcode, 'shortcode matches';
    }
    'builds shortcode from params for spot calle';
};

subtest 'call pricing engine equal tie markup' => sub {
    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            date_start   => $now,
            date_pricing => $now,
            duration     => '20m',
            barrier      => 'S0P',
            underlying   => 'frxUSDJPY',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });
        ok $c->pricing_engine->apply_equal_tie_markup, 'can apply_equal_tie_markup';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('equal_tie_markup'), '==', 0.02, 'correct equal tie markup';
    }
    'correct equal tie markup for USDJPY';

    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            date_start   => $now,
            date_pricing => $now,
            duration     => '20m',
            barrier      => 'S0P',
            underlying   => 'frxAUDCAD',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });
        ok $c->pricing_engine->apply_equal_tie_markup, 'can apply_equal_tie_markup';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('equal_tie_markup'), '==', 0.02, 'correct equal tie markup';
    }
    'correct equal tie markup for AUDCAD';

    lives_ok {
        my $c = produce_contract({
            bet_type             => 'CALLE',
            date_start           => $now,
            date_pricing         => $now,
            duration             => '20m',
            barrier              => 'S20P',
            underlying           => 'frxUSDJPY',
            currency             => 'USD',
            payout               => 10,
            product_type         => 'multi_barrier',
            trading_period_start => $now->epoch,
            current_tick         => $ct,
        });
        ok $c->pricing_engine->apply_equal_tie_markup, 'can apply_equal_tie_markup';
        cmp_ok $c->pricing_engine->risk_markup->peek_amount('equal_tie_markup'), '==', 0.02, 'correct equal tie markup';
    }
    'correct equal tie markup for USDJPY';

    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALL',
            date_start   => $now,
            date_pricing => $now,
            duration     => '20m',
            barrier      => 'S0P',
            underlying   => 'frxUSDJPY',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });

        ok !$c->pricing_engine->apply_equal_tie_markup, 'cant apply_equal_tie_markup';
        ok !defined $c->pricing_engine->risk_markup->peek_amount('equal_tie_markup'), 'no correct equal tie markup';
    }
    'no equal tie for call USDJPY';

    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            date_start   => $now,
            date_pricing => $now,
            duration     => '20m',
            barrier      => 'S0P',
            underlying   => 'WLDUSD',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });
        ok !$c->pricing_engine->apply_equal_tie_markup, 'can apply_equal_tie_markup ';
        ok !defined $c->pricing_engine->risk_markup->peek_amount('equal_tie_markup'), 'correct equal tie markup';
    }
    'no equal tie for call WLDUSD';

    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            date_start   => $now,
            date_pricing => $now,
            duration     => '20m',
            barrier      => 'S0P',
            underlying   => 'R_100',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });
        ok !defined $c->pricing_engine->can('apply_equal_tie_markup'), 'undefined apply_equal_tie_markup';
    }
    'no equal tie for R_100';
    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            date_start   => $now,
            date_pricing => $now,
            duration     => '7d',
            barrier      => 'S0P',
            underlying   => 'frxUSDJPY',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });
        ok $c->pricing_engine->apply_equal_tie_markup, 'can apply_equal_tie_markup';
        ok $c->ask_price, 'can ask price';
        cmp_ok $c->debug_information->{risk_markup}{parameters}{equal_tie_markup}, '==', 0.00, 'correct equal tie markup';
    }
    'correct equal tie markup for USDJPY';

    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            date_start   => $now,
            date_pricing => $now,
            duration     => '7d',
            barrier      => 'S0P',
            underlying   => 'frxAUDCAD',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });
        ok $c->pricing_engine->apply_equal_tie_markup, 'can apply_equal_tie_markup';
        ok $c->ask_price, 'can ask price';
        cmp_ok $c->debug_information->{risk_markup}{parameters}{equal_tie_markup}, '==', 0.00, 'correct equal tie markup';
    }
    'correct equal tie markup for AUDCAD';

    lives_ok {
        my $c = produce_contract({
            bet_type             => 'CALLE',
            date_start           => $now,
            date_pricing         => $now,
            duration             => '7d',
            barrier              => 'S20P',
            underlying           => 'frxUSDJPY',
            currency             => 'USD',
            payout               => 10,
            product_type         => 'multi_barrier',
            trading_period_start => $now->epoch,
            current_tick         => $ct,
        });
        ok $c->pricing_engine->apply_equal_tie_markup, 'can apply_equal_tie_markup';
        ok $c->ask_price, 'can ask price';
        cmp_ok $c->debug_information->{risk_markup}{parameters}{equal_tie_markup}, '==', 0.00, 'correct equal tie markup';

    }
    'correct equal tie markup for USDJPY';

    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALL',
            date_start   => $now,
            date_pricing => $now,
            duration     => '7d',
            barrier      => 'S0P',
            underlying   => 'frxUSDJPY',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });

        ok !$c->pricing_engine->apply_equal_tie_markup, 'cant apply_equal_tie_markup';
        ok $c->ask_price, 'can ask price';
        ok !defined $c->debug_information->{risk_markup}{parameters}{equal_tie_markup}, 'no correct equal tie markup';
    }
    'no equal tie for call USDJPY';

    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            date_start   => $now,
            date_pricing => $now,
            duration     => '7d',
            barrier      => 'S0P',
            underlying   => 'WLDUSD',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });
        ok !$c->pricing_engine->apply_equal_tie_markup, 'can not apply_equal_tie_markup ';
        ok $c->ask_price, 'can ask price';
        ok !defined $c->debug_information->{risk_markup}{parameters}{equal_tie_markup}, 'no defined correct equal tie markup';
    }
    'no equal tie for call WLDUSD';

    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            date_start   => $now,
            date_pricing => $now,
            duration     => '7d',
            barrier      => 'S0P',
            underlying   => 'R_100',
            currency     => 'USD',
            payout       => 10,
            current_tick => $ct,
        });
        ok $c->ask_price, 'can ask price';
        ok !defined $c->debug_information->{risk_markup}{parameters}{equal_tie_markup}, 'undefined apply_equal_tie_markup';
    }
    'no equal tie for R_100';

};
done_testing();
