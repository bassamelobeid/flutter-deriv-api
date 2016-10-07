#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 1;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Platform::Offerings qw(get_offerings_with_filter);
use BOM::Product::Contract::Finder qw(available_contracts_for_symbol);
use BOM::Product::ContractFactory qw(produce_contract);
use YAML::XS;

my $mocked_delta = Test::MockModule->new('Quant::Framework::VolSurface::Delta');
$mocked_delta->mock('get_volatility', sub { 0.1 });
my $mocked_money = Test::MockModule->new('Quant::Framework::VolSurface::Moneyness');
$mocked_money->mock('get_volatility', sub { 0.1 });
my $mocked_emp = Test::MockModule->new('BOM::MarketData::VolSurface::Empirical');
$mocked_emp->mock('get_volatility', sub { 0.1 });

my $now  = Date::Utility->new('2016-06-12 01:00:00');
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'XYZ',
    quote      => 100,
    epoch      => $now->epoch,
});
my $mocked_underlying = Test::MockModule->new('Quant::Framework::Underlying');
$mocked_underlying->mock('spot_tick', sub { return $tick });

subtest 'test everything' => sub {
    my $expected = YAML::XS::LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/Engine/selection_config.yml');
    foreach my $symbol (get_offerings_with_filter('underlying_symbol')) {
        foreach my $ref (@{available_contracts_for_symbol({symbol => $symbol})->{available}}) {
            next if $ref->{contract_category} eq 'spreads';
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
                %barriers
            });
            is $c->pricing_engine_name, $expected->{$c->shortcode}, "correct pricing engine select for " . $c->shortcode;
        }
    }
};
