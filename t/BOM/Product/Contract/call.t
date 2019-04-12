#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::Warnings;
use Test::Exception;
use Date::Utility;
use Cache::RedisDB;
use Format::Util::Numbers qw/roundcommon/;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::RedisReplicated;
use Test::MockModule;
use BOM::Config::Runtime;

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
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => $_,
    }) for qw( USD JPY JPY-USD );
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => $_,
    }) for qw( USD AUD CAD-AUD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw (frxUSDJPY frxAUDCAD frxUSDCAD frxAUDUSD);
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
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
my $redis     = BOM::Config::RedisReplicated::redis_write();
my $undec_key = "DECIMATE_frxAUDCAD" . "_31m_FULL";
my $encoder   = Sereal::Encoder->new({
    canonical => 1,
});
my %defaults = (
    symbol => 'frxAUDCAD',
    epoch  => $now->epoch,
    quote  => 0.9935,
    bid    => 0.9935,
    ask    => 0.9935,
    count  => 1,
);
$redis->zadd($undec_key, $defaults{epoch}, $encoder->encode(\%defaults));

$defaults{epoch} = $now->epoch + 1;
$defaults{quote} = 0.9936;
$redis->zadd($undec_key, $defaults{epoch}, $encoder->encode(\%defaults));

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
        cmp_ok $c->ask_price, '==', 6.48, 'correct ask price';
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
        isa_ok $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope';

        $args->{duration}     = '10m';
        $args->{date_pricing} = $now->plus_time_interval('10m');
        $args->{date_start}   = $now->plus_time_interval('20m');
        $c                    = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Call';
        ok $c->is_forward_starting,     'forward starting';
        isa_ok $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope';

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
        isa_ok $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope';
    }
    'pricing engine selection';
};

subtest 'shortcodes' => sub {
    my $ct = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => time
    });
    lives_ok {
        my $c =
            produce_contract('CALL_FRXUSDJPY_10_' . $now->plus_time_interval('10m')->epoch . 'F_' . $now->plus_time_interval('20m')->epoch . '_S0P_0',
            'USD');
        isa_ok $c, 'BOM::Product::Contract::Call';
        ok $c->starts_as_forward_starting;
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
            current_tick => $ct,
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
    date_pricing => $now->plus_time_interval('1s'),
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
        cmp_ok $c->barrier->as_absolute, 'eq', '0.99360', 'correct absolute barrier (it will be pipsized) ';
        cmp_ok $c->entry_tick->quote,    'eq', '0.9936',  'correct entry tick';
        cmp_ok $c->current_spot, 'eq', '0.99360', 'correct current spot (it will be pipsized)';
        cmp_ok $c->ask_price,    'eq', '6.50',    'correct ask price';
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
        cmp_ok $c->exit_tick->quote, 'eq', '0.9939', 'correct exit tick';

    }
    'variable checking';
};

