#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 6;
use Test::Exception;
use Test::NoWarnings;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw(USD JPY AUD CAD JPY-USD AUD-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(frxUSDJPY frxAUDCAD);
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch + 1,
    quote      => 100,
});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxAUDCAD',
    epoch      => $now->epoch,
    quote      => 0.9935
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxAUDCAD',
    epoch      => $now->epoch + 1,
    quote      => 0.9936,
});

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

subtest 'call variations' => sub {
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Call';
        is $c->code,        'CALL';
        ok $c->is_intraday, 'is intraday';
        ok !$c->expiry_daily, 'not expiry daily';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
        isa_ok $c->barrier,        'BOM::Product::Contract::Strike';
        cmp_ok $c->barrier->as_absolute, '==', 76.900, 'correct absolute barrier';
        ok $c->theo_probability;
    }
    'generic';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Call';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';

        $args->{duration} = '5h1s';
        $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Call';
        isa_ok $c->pricing_engine, 'Pricing::Engine::EuropeanDigitalSlope';

        $args->{duration}     = '10m';
        $args->{date_pricing} = $now->plus_time_interval('10m');
        $args->{date_start}   = $now->plus_time_interval('20m');
        $c                    = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Call';
        ok $c->is_forward_starting, 'forward starting';
        isa_ok $c->pricing_engine,  'Pricing::Engine::EuropeanDigitalSlope';

        $args->{date_pricing} = $now;
        $args->{date_start}   = $now;
        $args->{duration}     = '15m';
        $args->{barrier}      = 'S10P';
        $c                    = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Call';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';

        $args->{duration} = '5h1s';
        $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Call';
        isa_ok $c->pricing_engine, 'Pricing::Engine::EuropeanDigitalSlope';
    }
    'pricing engine selection';
};

subtest 'entry conditions' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s');
    my $c = produce_contract($args);
    ok !$c->pricing_new;
    ok !$c->is_forward_starting;
    ok $c->entry_tick, 'has entry tick';
    is $c->entry_tick->epoch, $now->epoch + 1, 'got the right entry tick for contract starting now';
};

subtest 'expiry conditions' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s');
    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    cmp_ok $c->value, '==', 0, 'value 0';
    $args->{duration}     = '10m';
    $args->{date_start}   = $now;
    $args->{date_pricing} = $now->plus_time_interval('10m');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch + 509,
        quote      => 101,
    });
    $c = produce_contract($args);
    ok !$c->exit_tick,  'no exit tick';
    ok !$c->is_expired, 'not expired without exit tick';
    cmp_ok $c->value, '==', 0;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch + 601,
        quote      => 101,
    });
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->exit_tick,  'has exit tick';
    ok $c->exit_tick->quote > $c->barrier->as_absolute;
    cmp_ok $c->value, '==', $c->payout, 'full payout';
};

subtest 'missing market data conditions' => sub {
    $args->{duration}     = '15m';
    $args->{date_start}   = $now;
    $args->{date_pricing} = $now->plus_time_interval('15m');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch + 899,
        quote      => 101,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch + 901,
        quote      => 101,
    });
    my $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->exit_tick,  'has exit tick';
    ok !$c->missing_market_data, 'has no misisng market data';

    $args->{duration}     = '30m';
    $args->{date_start}   = $now;
    $args->{date_pricing} = $now->plus_time_interval('30m');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch + 1499,
        quote      => 101,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch + 1801,
        quote      => 101,
    });
    $c = produce_contract($args);
    ok $c->is_expired,          'expired';
    ok $c->exit_tick,           'has exit tick';
    ok $c->missing_market_data, 'has misisng market data';
};

subtest 'shortcodes' => sub {
    lives_ok {
        my $c =
            produce_contract('CALL_FRXUSDJPY_10_' . $now->plus_time_interval('10m')->epoch . 'F_' . $now->plus_time_interval('20m')->epoch . '_S0P_0',
            'USD');
        isa_ok $c, 'BOM::Product::Contract::Call';
        ok $c->is_forward_starting;
    }
    'builds forward starting call from shortcode';
    lives_ok {
        my $c = produce_contract('CALL_FRXUSDJPY_10_' . $now->epoch . '_' . $now->plus_time_interval('20m')->epoch . '_S0P_0', 'USD');
        isa_ok $c, 'BOM::Product::Contract::Call';
        ok !$c->is_forward_starting;
    }
    'builds spot call from shortcode';
    lives_ok {
        my $c = produce_contract({
            bet_type     => 'CALL',
            date_start   => $now,
            date_pricing => $now->minus_time_interval('10m'),
            duration     => '20m',
            barrier      => 'S0P',
            underlying   => 'frxUSDJPY',
            currency     => 'USD',
            payout       => 10,
        });
        isa_ok $c, 'BOM::Product::Contract::Call';
        my $expected_shortcode = 'CALL_FRXUSDJPY_10_' . $now->epoch . 'F_' . $now->plus_time_interval('20m')->epoch . '_S0P_0';
        is $c->shortcode, $expected_shortcode, 'shortcode matches';
    }
    'builds shortcode from params for forward starting call';
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
        });
        isa_ok $c, 'BOM::Product::Contract::Call';
        my $expected_shortcode = 'CALL_FRXUSDJPY_10_' . $now->epoch . '_' . $now->plus_time_interval('20m')->epoch . '_S0P_0';
        is $c->shortcode, $expected_shortcode, 'shortcode matches';
    }
    'builds shortcode from params for spot call';
};

$args = {
    bet_type     => 'CALL',
    underlying   => 'frxAUDCAD',
    date_start   => $now,
    date_pricing => $now,
    duration     => '10m',
    currency     => 'USD',
    payout       => 10,
    barrier      => 'S0P',
};

subtest 'pips size changes' => sub {
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Call';
        is $c->code,               'CALL';
        ok $c->is_intraday,        'is intraday';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
        cmp_ok $c->barrier->as_absolute, 'eq', 0.99360, 'correct absolute barrier';
        cmp_ok $c->entry_tick, 'eq', 0.99360, 'correct entry tick';

        $args->{date_pricing} = $now->plus_time_interval('10m');
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxAUDCAD',
            epoch      => $now->epoch + 599,
            quote      => 0.9939,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxAUDCAD',
            epoch      => $now->epoch + 601,
            quote      => 0.9938,
        });
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->exit_tick,  'has exit tick';
        ok $c->exit_tick->quote > $c->barrier->as_absolute;
        cmp_ok $c->value, '==', $c->payout, 'full payout';
        cmp_ok $c->exit_tick, 'eq', 0.99390, 'correct exit tick';

    }
    'variable checking';
};

