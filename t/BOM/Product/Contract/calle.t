#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Warnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use Date::Utility;
use LandingCompany::Offerings qw(reinitialise_offerings);
use BOM::Product::ContractFactory qw(produce_contract);
use Test::MockModule;

my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + rand(0.005)} } (0 .. 80)];
    });
reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'JPY',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'JPY-USD',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        underlying    => create_underlying('frxUSDJPY'),
        recorded_date => $now
    });
my $ct = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch + 1,
    quote      => 100,
});

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
        $args->{barrier}      = 'S10P';
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
        quote      => 100.010,
    });
    $c = produce_contract($args);
    ok $c->exit_tick, 'There is exit tick';
    ok !$c->is_valid_exit_tick, 'The exit tick is not valid';
    ok $c->is_expired, 'Is expired';
    ok !$c->is_settleable,    'It is not settleable as there is no valid exit tick';
    ok !$c->is_valid_to_sell, 'It is not valid to sell due to no valid exit tick';
    like($c->primary_validation_error->message, qr/exit tick is undefined/, 'throws error');
    cmp_ok $c->value, '==', 10;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch + 601,
        quote      => 101,
    });
    $c = produce_contract($args);
    ok $c->is_expired,         'expired';
    ok $c->exit_tick,          'has exit tick';
    ok $c->is_valid_exit_tick, 'is valid exit tick';
    ok $c->is_settleable,      'is settleable';
    ok $c->is_valid_to_sell,   'is valid to sell';
    ok $c->exit_tick->quote == $c->barrier->as_absolute;
    cmp_ok $c->value, '==', $c->payout, 'full payout';
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
