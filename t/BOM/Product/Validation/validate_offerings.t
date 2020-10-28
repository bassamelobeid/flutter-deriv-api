#!/etc/rmg/bin/perl

use Test::More;
use Test::Warnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;

use BOM::Config::Runtime;
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
subtest 'custom suspend trading' => sub {
    my $orig = BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles;
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
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

subtest 'suspend early sellback' => sub {
    my $orig = BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_early_sellback;
    $underlying = 'R_100';
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $underlying],
        [101, $now->epoch + 1, $underlying],
        [102, $now->epoch + 2, $underlying]);
    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_start   => $now,
        date_pricing => $now->epoch + 1,
        duration     => '3d',
        barrier      => 'S0P',
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell';

    note "setting underlyings->suspend_early_sellback(['R_100'])";
    BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_early_sellback(['R_100']);

    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'invalid to sell';
    is $c->primary_validation_error->message, 'early sellback disabled for underlying', 'message - early sellback disabled for underlying';
    is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';

    $underlying = 'R_10';
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $underlying],
        [101, $now->epoch + 1, $underlying],
        [102, $now->epoch + 2, $underlying]);
    $bet_params->{underlying} = $underlying;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell';

    note "resetting underlyings->suspend_early_sellback";
    BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_early_sellback($orig);

    $orig = BOM::Config::Runtime->instance->app_config->quants->markets->suspend_early_sellback;
    note "setting markets->suspend_early_sellback(['synthetic_index'])";
    BOM::Config::Runtime->instance->app_config->quants->markets->suspend_early_sellback(['synthetic_index']);

    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'invalid to sell';
    is $c->primary_validation_error->message, 'early sellback disabled for market', 'message - early sellback disabled for market';
    is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';

    $underlying = 'frxUSDJPY';
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $underlying],
        [101, $now->epoch + 1, $underlying],
        [102, $now->epoch + 2, $underlying]);
    $bet_params->{underlying} = $underlying;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell';

    note "resetting markets->suspend_early_sellback";
    BOM::Config::Runtime->instance->app_config->quants->markets->suspend_early_sellback($orig);

    $orig = BOM::Config::Runtime->instance->app_config->quants->contract_types->suspend_early_sellback;
    note "setting contract_types->suspend_early_sellback(['CALL'])";
    BOM::Config::Runtime->instance->app_config->quants->contract_types->suspend_early_sellback(['CALL']);

    $c = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell because you are selling a PUT';

    $bet_params->{bet_type} = 'PUT';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'invalid to sell';
    is $c->primary_validation_error->message, 'early sellback disabled for contract type', 'message - early sellback disabled for contract_types';
    is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,      $underlying],
        [101, $now->epoch + 1,  $underlying],
        [102, $now->epoch + 2,  $underlying],
        [103, $now->epoch + 12, $underlying]);
    $bet_params->{duration}     = '10s';
    $bet_params->{date_pricing} = $now->epoch + 12;
    $c                          = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell after settlement time';

    $c = produce_contract($bet_params);
    BOM::Config::Runtime->instance->app_config->quants->contract_types->suspend_early_sellback(['PUT']);
    BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_early_sellback(['frxUSDJPY']);
    $bet_params->{date_pricing} = $now->epoch + 1;
    $bet_params->{duration} = '3d';

    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'invalid to sell';
    is $c->primary_validation_error->message, 'early sellback disabled for underlying', 'message - early sellback disabled for underlying';
    is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';
};

done_testing();
