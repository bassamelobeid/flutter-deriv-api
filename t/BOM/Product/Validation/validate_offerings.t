#!/etc/rmg/bin/perl

use Test::More tests => 3;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Test::MockModule;

my $now = Date::Utility->new('2016-03-15 01:00:00');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD AUD AUD-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxAUDUSD',
        recorded_date => $now
    });
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxAUDUSD',
    epoch      => $now->epoch
});
my $bet_params = {
    underlying   => 'frxAUDUSD',
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 100,
    date_start   => $now,
    date_pricing => $now,
    duration     => '3d',
    barrier      => 'S0P',
    current_tick => $tick,
};

my $mocked_FA = Test::MockModule->new('Finance::Asset');
$mocked_FA->mock('cached_underlyings', sub { {} });

note("Validation runs on " . $now->datetime);
subtest 'system wide suspend trading' => sub {
    BOM::Platform::Runtime->instance->app_config->system->suspend->trading(1);
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/All trading suspended on system/, 'trading suspended message');
    BOM::Platform::Runtime->instance->app_config->system->suspend->trading(0);
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'ok to buy';
};

subtest 'invalid underlying - contract type combination' => sub {
    $bet_params->{is_forward_starting} = 1;
    $bet_params->{barrier}             = 'S100P';                                                  # non atm
    $bet_params->{date_start}          = $bet_params->{date_pricing}->plus_time_interval('20m');
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/trying unauthorised combination/, 'Contract type suspended message');
    delete $bet_params->{is_forward_starting};
    $bet_params->{date_start} = $bet_params->{date_pricing};
};

subtest 'custom suspend trading' => sub {
    my $orig = BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles;
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "forex", "contract_category":"callput", "expiry_type": "tick", "risk_profile": "no_business"}}');
    $bet_params->{underlying} = 'frxUSDJPY';
    $bet_params->{bet_type}   = 'CALL', $bet_params->{duration} = '5t';
    $bet_params->{barrier}    = 'S0P';

    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->message, qr/manually disabled by quants/, 'throws error');
    $bet_params->{underlying} = 'R_100';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for random';
};
