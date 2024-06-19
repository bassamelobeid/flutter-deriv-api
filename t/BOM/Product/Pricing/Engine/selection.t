#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);

use LandingCompany::Registry;
use BOM::Product::Offerings::TradingContract qw(get_contracts);
use BOM::Product::ContractFinder::Basic;
use BOM::Product::ContractFactory qw(produce_contract);
use YAML::XS;
use List::Util;

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
my $offerings_cfg = BOM::Config::Runtime->instance->get_offerings_config;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw(USD JPY AUD CAD AUD-USD EUR-USD GBP-USD USD-JPY CAD-USD XAG XAU);

subtest 'test everything' => sub {
    my $expected = YAML::XS::LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/Engine/selection_config.yml');
    foreach my $symbol (LandingCompany::Registry->by_name('svg')->basic_offerings($offerings_cfg)->values_for_key('underlying_symbol')) {
        foreach my $ref (
            @{
                BOM::Product::ContractFinder::Basic::decorate({
                        offerings            => get_contracts({symbol => $symbol}),
                        symbol               => $symbol,
                        landing_company_name => 'virtual'
                    }
                )->{available}})
        {
            my (%barriers, %selected_tick);
            if ($ref->{contract_category} eq 'digits' and $ref->{contract_type} !~ /(?:odd|even)/i) {
                %barriers = (barrier => 1);
            } elsif ($ref->{contract_category} eq 'highlowticks') {
                %selected_tick = (selected_tick => 1);
            } elsif ($ref->{contract_category} eq 'callputspread') {
                %barriers = (barrier_range => 'middle');
            } else {
                %barriers =
                    $ref->{barriers} == 2
                    ? (
                    high_barrier => $ref->{high_barrier},
                    low_barrier  => $ref->{low_barrier})
                    : (barrier => $ref->{barrier});
            }
            my $contract_args = {
                bet_type     => $ref->{contract_type},
                underlying   => $symbol,
                date_start   => $now,
                date_pricing => $now,
                duration     => $ref->{min_contract_duration},
                currency     => 'USD',
                payout       => 100,
            };
            if (List::Util::any { $ref->{contract_type} eq $_ } qw(LBFLOATCALL LBFLOATPUT LBHIGHLOW)) {
                $contract_args->{multiplier} = 5;
                delete $contract_args->{payout};
            } elsif (
                List::Util::any {
                    $ref->{contract_type} eq $_
                }
                qw(TICKHIGH TICKLOW)
                )
            {
                $contract_args->{selected_tick} = 1;
            } elsif ($ref->{contract_category} eq 'runs' or ($ref->{contract_category} =~ /callput/ and $ref->{barrier_category} eq 'euro_atm')) {
                $contract_args->{barrier} = 'S0P';
            } else {
                $contract_args = {%$contract_args, %barriers};
            }

            # there's no pricing engine for multiplier and accumulator
            next
                if $contract_args->{bet_type} =~
                /\bMULTUP\b|\bMULTDOWN\b|\bACCU\b|\bVANILLALONGCALL\b|\bVANILLALONGPUT\b|\bTURBOSLONG\b|\bTURBOSSHORT\b/;

            my $c = produce_contract($contract_args);

            next unless exists $expected->{$c->shortcode};
            is $c->pricing_engine_name, $expected->{$c->shortcode}, "correct pricing engine select for " . $c->shortcode;
        }
    }
};
