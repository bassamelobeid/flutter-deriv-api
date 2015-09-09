#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 8;
use Test::NoWarnings;
use Test::Exception;
use Test::MockModule;

use Scalar::Util qw(looks_like_number);

use BOM::Product::Pricing::Engine::TickExpiry;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use Date::Utility;
use BOM::Product::Pricing::Engine::TickExpiry;

my $now = Date::Utility->new('24-Dec-2014');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange');

# Extra currencies are to cover WLDUSD components
foreach my $needed_currency (qw(USD GBP JPY AUD EUR)) {
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => $needed_currency});
}

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxGBPUSD',
        recorded_date => $now,
    });

my @ticks = map { {epoch => $now->epoch + $_, quote => rand(1)} } (-20 .. -1);
subtest 'insufficient arguments' => sub {
    my $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'CALL',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks
    });
    like $ref->{error}, qr/Insufficient input to calculate probability/, 'error if insufficient arguments';
    is $ref->{probability}, 1, 'probability is 1 if error';
    is $ref->{markups}->{model_markup},      0, 'model_markup is 0 if error';
    is $ref->{markups}->{risk_markup},       0, 'risk_markup is 0 if error';
    is $ref->{markups}->{commission_markup}, 0, 'commission_markup is 0 if error';
    ok !$ref->{debug_info}, 'debug information undef';
};

subtest 'invalid contract type' => sub {
    my $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'CALL',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks,
        economic_events   => [],
        date_pricing      => $now
    });
    ok !$ref->{error}, 'no error for CALL contract_type';
    $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'PUT',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks,
        economic_events   => [],
        date_pricing      => $now
    });
    ok !$ref->{error}, 'no error for PUT contract_type';
    $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'EXPIRYMISS',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks,
        economic_events   => [],
        date_pricing      => $now
    });
    like $ref->{error}, qr/Could not calculate probability for EXPIRYMISS/, 'error if invalid contract_type';
    is $ref->{probability}, 1, 'probability is 1 if error';
    is $ref->{markups}->{model_markup},      0, 'model_markup is 0 if error';
    is $ref->{markups}->{risk_markup},       0, 'risk_markup is 0 if error';
    is $ref->{markups}->{commission_markup}, 0, 'commission_markup is 0 if error';
    ok !$ref->{debug_info}, 'debug information undef';
};

subtest 'ticks too old' => sub {
    my $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
            contract_type     => 'CALL',
            underlying_symbol => 'frxUSDJPY',
            last_twenty_ticks => \@ticks,
            economic_events   => [],
            date_pricing      => $now->plus_time_interval('4m40s')});
    like $ref->{error}, qr/Do not have enough ticks to calculate volatility/, 'error if we do not have recent ticks to calculate vol/trend proxy';
    is $ref->{debug_info}->{base_vol_proxy}, 0.2, 'vol proxy set to 20% on error';
    ok looks_like_number($ref->{probability}), 'still get a probability';
};

subtest 'insufficient ticks to calculate probability' => sub {
    my $shifted_tick = shift @ticks;
    my $ref          = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'CALL',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks,
        economic_events   => [],
        date_pricing      => $now
    });
    like $ref->{error}, qr/Do not have enough ticks to calculate volatility/, 'error if we do not have enough ticks to calculate vol/trend proxy';
    is $ref->{debug_info}->{base_vol_proxy}, 0.2, 'vol proxy set to 20% on error';
    ok looks_like_number($ref->{probability}), 'still get a probability';
    unshift @ticks, $shifted_tick;
};

subtest 'coefficient sanity check' => sub {
    my $module = Test::MockModule->new('BOM::Product::Pricing::Engine::TickExpiry');
    my $coef   = {
        frxUSDJPY => {
            x_prime_min => -2.92896,
            x_prime_max => 2.92352,
            y_min       => 4.90366e-06,
            y_max       => 3.35274e-05,
            A           => -69175.5,
            B           => 7.71357e+06,
            C           => 163.199,
            D           => 0.00185616,
            tie_A       => -0.00048763,
            tie_B       => 0.0684276,
            tie_C       => 1926.39,
        }};
    $module->mock('_coefficients', sub { return $coef });
    my $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'CALL',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks,
        economic_events   => [],
        date_pricing      => $now
    });
    like $ref->{error}, qr/Invalid coefficients for probability calculation/, 'error if insufficient coefficients';
    is $ref->{probability}, 1, 'default probability of 1 if error';
    $coef->{frxUSDJPY}->{tie_D} = 'string';
    $module->mock('_coefficients', sub { return $coef});
    $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'CALL',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks,
        economic_events   => [],
        date_pricing      => $now
    });
    like $ref->{error}, qr/Invalid coefficients for probability calculation/, 'error if insufficient coefficients';
    is $ref->{probability}, 1, 'default probability of 1 if error';
    $coef->{frxUSDJPY}->{tie_D} = -21.3305;
    $module->mock('_coefficients', sub { return $coef});
    $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'CALL',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks,
        economic_events   => [],
        date_pricing      => $now
    });
    ok !$ref->{error}, 'no error';
};

subtest 'add 3% to risk_markup if vol_proxy is outside benchmark' => sub {
    # only testing for one hit condition, vol_proxy > y_max.
    my $module = Test::MockModule->new('BOM::Product::Pricing::Engine::TickExpiry');
    my $coef   = {
        frxUSDJPY => {
            x_prime_min => -2.92896,
            x_prime_max => 2.92352,
            y_min       => 4.90366e-06,
            y_max       => 0.00001,
            A           => -69175.5,
            B           => 7.71357e+06,
            C           => 163.199,
            D           => 0.00185616,
            tie_A       => -0.00048763,
            tie_B       => 0.0684276,
            tie_C       => 1926.39,
            tie_D       => -21.23
        }};
    $module->mock('_coefficients', sub { return $coef });
    $module->mock('_get_proxy', sub {return (0.0001, 0, undef)});
    my $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'CALL',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks,
        economic_events   => [],
        date_pricing      => $now
    });
    is $ref->{debug_info}->{base_vol_proxy}, 0.0001, '0.2 base vol_proxy';
    is $ref->{debug_info}->{coefficients}->{y_max}, 1e-05, 'vol_proxy max is 0.9';
    is $ref->{debug_info}->{vol_proxy}, 0.00001, 'final vol_proxy set to max';
    is $ref->{debug_info}->{base_risk_markup}, -0.00770862947798449, 'base risk markup';
    is $ref->{debug_info}->{risk_markup}, 0.0222913705220155, 'risk markup adjusted';
    $module->unmock_all;
};

subtest 'tie factor' => sub {
    my $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'CALL',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks,
        economic_events   => [],
        date_pricing      => $now
    });
    is $ref->{debug_info}->{tie_factor}, 0.75, 'discount tie adjustment for 75% if no economic event';
    $ref = BOM::Product::Pricing::Engine::TickExpiry::probability({
        contract_type     => 'CALL',
        underlying_symbol => 'frxUSDJPY',
        last_twenty_ticks => \@ticks,
        economic_events   => [{name => 'test event', impact => 5, release_date => $now, source => 'forexfactory'}],
        date_pricing      => $now
    });
    is $ref->{debug_info}->{tie_factor}, 0, 'do not discount if there is economic event';
};
