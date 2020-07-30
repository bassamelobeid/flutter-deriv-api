use Test::Most;
use Test::Warnings;
use Test::MockModule;
use File::Spec;

use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::Pricing::Engine::Intraday::Forex;
use BOM::MarketData qw(create_underlying_db);

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD JPY EUR/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'OTC_FCHI',
        date   => Date::Utility->new,
    });

initialize_realtime_ticks_db();

my $bet_params = {
    bet_type   => 'PUT',
    underlying => 'frxUSDJPY',
    duration   => '15m',
    barrier    => 'S0P',
    payout     => 1,
    currency   => 'USD'
};

my $bet;
lives_ok { $bet = produce_contract($bet_params); } 'Can create example PUT bet';

my $pe;
lives_ok { $pe = BOM::Product::Pricing::Engine::Intraday::Forex->new({bet => $bet}) } 'Can create IH engine using PUT bet';

throws_ok { $pe = BOM::Product::Pricing::Engine::Intraday::Forex->new() } qr/Attribute \(bet\) is required/, 'Requires bet for construction';

delete $bet_params->{date_start};
$bet_params->{bet_type} = 'ONETOUCH';
$bet_params->{duration} = '1h';
lives_ok { $bet = produce_contract($bet_params); } 'Can create example ONETOUCH bet';
lives_ok { $pe = BOM::Product::Pricing::Engine::Intraday::Forex->new({bet => $bet}) } 'Can create IH engine using ONETOUCH bet';

SKIP: {
    skip("There aren't any underlyings with EXPIRYMISS enabled currently, although the engine should be able to support it.", 1);
    delete $bet_params->{date_start};
    $bet_params->{bet_type} = 'EXPIRYMISS';

    lives_ok { $bet = produce_contract($bet_params); } 'Can create example EXPIRYMISS bet';
    lives_ok { $pe = BOM::Product::Pricing::Engine::Intraday::Forex->new({bet => $bet}) } 'Can create IH engine using EXPIRYMISS bet';
}
delete $bet_params->{date_start};
$bet_params->{bet_type} = 'PUT';
$bet_params->{duration} = '1d';

lives_ok { $bet = produce_contract($bet_params); } 'Can create example PUT bet';
ok $bet->expiry_daily;
is $bet->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope', 'expiry_daily contract uses slope pricer';

delete $bet_params->{date_start};
$bet_params->{bet_type} = 'RANGE';
lives_ok { $bet = produce_contract(+{%$bet_params, high_barrier => 'S20P', low_barrier => 'S-10P'}); } 'Can create example RANGE bet';
throws_ok { $pe = BOM::Product::Pricing::Engine::Intraday::Forex->new({bet => $bet}) } qr/Invalid claimtype/,
    'Cannot create engine for two barrier path-dependents (RANGE)';

my $now = time;
$bet_params->{date_start}   = $now;
$bet_params->{bet_type}     = 'PUT';
$bet_params->{duration}     = '15m';
$bet_params->{date_pricing} = $now - 300;

lives_ok { $bet = produce_contract($bet_params); } 'Can create example PUT bet';
ok !$bet->expiry_daily;
ok $bet->is_forward_starting;
is $bet->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope', 'forward starting bet incompatible with IH';

delete $bet_params->{date_start};
$bet_params->{bet_type}   = 'CALL';
$bet_params->{underlying} = 'OTC_FCHI';

lives_ok { $bet = produce_contract($bet_params); } 'Can create example OTC_FCHI bet';
is $bet->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope', 'unsupported symbol';

delete $bet_params->{date_start};
delete $bet_params->{date_pricing};
$bet_params->{bet_type}   = 'CALL';
$bet_params->{barrier}    = 'S10P';        # non_atm
$bet_params->{duration}   = '14m59s';
$bet_params->{underlying} = 'frxUSDJPY';

lives_ok { $bet = produce_contract($bet_params); } 'Can create example 14m59s bet';
ok !$bet->is_forward_starting;
ok !$bet->expiry_daily;
is $bet->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope', 'slope pricer for duration (14m59s)';
$bet_params->{duration} = '15m';
$bet = produce_contract($bet_params);
is $bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday historical forex pricer for duration (15m)';
$bet_params->{duration} = '5h1s';
$bet = produce_contract($bet_params);
is $bet->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope', 'slope pricer for duration (5h1s)';
done_testing;
