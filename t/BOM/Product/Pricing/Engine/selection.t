#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use LandingCompany::Registry;
use BOM::Product::ContractFinder;
use BOM::Product::ContractFactory qw(produce_contract);
use YAML::XS;

use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db;

my $mocked_delta = Test::MockModule->new('Quant::Framework::VolSurface::Delta');
$mocked_delta->mock('get_volatility',          sub { 0.1 });
$mocked_delta->mock('get_surface_volatility',  sub { 0.1 });
$mocked_delta->mock('original_term_for_smile', sub { [1] });
my $mocked_money = Test::MockModule->new('Quant::Framework::VolSurface::Moneyness');
$mocked_money->mock('get_volatility',          sub { 0.1 });
$mocked_money->mock('get_surface_volatility',  sub { 0.1 });
$mocked_money->mock('original_term_for_smile', sub { [1] });
my $mocked_emp = Test::MockModule->new('VolSurface::Empirical');
$mocked_emp->mock('get_volatility', sub { 0.1 });

my $now  = Date::Utility->new('2016-06-12 01:00:00');
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'XYZ',
    quote      => 100,
    epoch      => $now->epoch,
});
my $mocked_underlying = Test::MockModule->new('Quant::Framework::Underlying');
$mocked_underlying->mock('spot_tick', sub { return $tick });
my $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;

subtest 'test everything' => sub {
    my $expected = YAML::XS::LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/Engine/selection_config.yml');
    foreach my $symbol (LandingCompany::Registry::get('costarica')->basic_offerings($offerings_cfg)->values_for_key('underlying_symbol')) {
        foreach my $ref (@{BOM::Product::ContractFinder->new->basic_contracts_for({symbol => $symbol})->{available}}) {
            my %barriers;
            if ($ref->{contract_category} eq 'digits') {
                %barriers = (barrier => 1);
            } else {
                %barriers =
                    $ref->{barriers} == 2
                    ? (
                    high_barrier => $ref->{high_barrier},
                    low_barrier  => $ref->{low_barrier})
                    : (barrier => $ref->{barrier});
            }
            my $c = produce_contract({
                bet_type     => $ref->{contract_type},
                underlying   => $symbol,
                date_start   => $now,
                date_pricing => $now,
                duration     => $ref->{min_contract_duration},
                currency     => 'USD',
                payout       => 100,
                unit         => 1,
                %barriers
            });
            next unless exists $expected->{$c->shortcode};
            is $c->pricing_engine_name, $expected->{$c->shortcode}, "correct pricing engine select for " . $c->shortcode;
        }
    }
};
