#!/etc/rmg/bin/perl

use BOM::Config::Runtime;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Product::ContractFactory                qw(produce_contract);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use Date::Utility;
use Test::MockModule;
use Test::More;
use Test::Warnings;

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
    epoch      => $now->epoch,
    quote      => 1.00
});

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [1.00, $now->epoch,     'frxAUDUSD'],
    [1.01, $now->epoch + 1, 'frxAUDUSD'],
    [1.03, $now->epoch + 2, 'frxAUDUSD']);

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

my $mocked_FU = Test::MockModule->new('Finance::Underlying');
$mocked_FU->mock('cached_underlyings', sub { {} });

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

    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "forex", "contract_category":"callput", "expiry_type": "daily", "risk_profile": "no_business"}}');

    $bet_params->{underlying}   = 'frxAUDUSD';
    $bet_params->{duration}     = '3d';
    $bet_params->{date_pricing} = $bet_params->{date_pricing}->plus_time_interval('2s');
    $c                          = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'cannot buy because risk_profile is no_business';

    $bet_params->{for_sale} = 1;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sellback even daily forex callput is in no_business';

    # Reset custom product profiles settings to test market and symbol risk profile
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles('{}');
    $orig = BOM::Config::Runtime->instance->app_config->quants->custom_volume_limits(
        '{"markets":{"forex":{"max_volume_positions":2,"risk_profile":"no_business"}}}');

    $bet_params = {
        amount       => 100,
        basis        => 'stake',
        bet_type     => 'MULTUP',
        currency     => 'USD',
        current_tick => $tick,
        date_pricing => $now,
        date_start   => $now,
        multiplier   => 30,
        stake        => 100,
        underlying   => 'frxAUDUSD',
    };

    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'cannot buy because forex risk_profile is no_business';
    like($c->primary_validation_error->message, qr/manually disabled by quants/, 'throws error');

    $bet_params->{underlying} = 'R_100';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for non-forex symbol';

    BOM::Config::Runtime->instance->app_config->quants->custom_volume_limits(
        '{"symbols":{"1HZ10V":{"max_volume_positions":3,"risk_profile":"low_risk"},"1HZ150V":{"max_volume_positions":4,"risk_profile":"no_business"}}}'
    );

    $bet_params->{underlying} = '1HZ150V';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'cannot buy because 1HZ150V risk_profile is no_business';
    like($c->primary_validation_error->message, qr/manually disabled by quants/, 'throws error');

    $bet_params->{underlying} = '1HZ10V';
    $bet_params->{multiplier} = 100;
    $c                        = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy because 1HZ10V is low_risk';
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
    $bet_params->{duration}     = '3d';

    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'invalid to sell';
    is $c->primary_validation_error->message, 'early sellback disabled for underlying', 'message - early sellback disabled for underlying';
    is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';
    BOM::Config::Runtime->instance->app_config->quants->contract_types->suspend_early_sellback($orig);
};

subtest 'callputspreads suspend early sellback' => sub {

    my $original_disable_sellback      = BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback;
    my $original_min_duration          = BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration;
    my $original_suspend_markets       = BOM::Config::Runtime->instance->app_config->quants->markets->suspend_early_sellback;
    my $original_suspend_underlyings   = BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_early_sellback;
    my $original_suspend_contract_type = BOM::Config::Runtime->instance->app_config->quants->contract_types->suspend_early_sellback;

    BOM::Config::Runtime->instance->app_config->quants->markets->suspend_early_sellback([]);
    BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_early_sellback([]);
    BOM::Config::Runtime->instance->app_config->quants->contract_types->suspend_early_sellback([]);
    my $args = {
        bet_type     => 'CALLSPREAD',
        underlying   => 'R_10',
        date_start   => $now,
        date_pricing => $now->epoch + 300,
        high_barrier => 'S10P',
        low_barrier  => 'S-10P',
        duration     => '30m',
        currency     => 'USD',
        payout       => 100,
    };

    subtest 'Volatility Indices' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch + 1,   $args->{underlying}],
            [100, $now->epoch + 300, $args->{underlying}],
            [100, $now->epoch + 400, $args->{underlying}]);

        subtest 'CALLSPREAD' => sub {
            my $c = produce_contract($args);
            ok !$c->is_expired, 'contract is not expired';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(0);
            BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration(900);    #15 minutes
            $c = produce_contract($args);
            ok $c->is_valid_to_sell, 'is valid to sell';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(1);
            $c = produce_contract($args);
            ok !$c->is_valid_to_sell, 'is invalid to sell';
            is $c->primary_validation_error->message,                'early sellback disabled for call/put Spreads';
            is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(0);
            BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration(1500);    # 25 minutes
            $c = produce_contract($args);
            ok !$c->is_valid_to_sell, 'is invalid to sell';
            is $c->primary_validation_error->message,                'remaing contract duration should be more than 1500 seconds for sellback';
            is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration(1800);    # 30 minutes
            $c = produce_contract($args);
            ok !$c->is_valid_to_sell, 'is invalid to sell';
            is $c->primary_validation_error->message,                'remaing contract duration should be more than 1800 seconds for sellback';
            is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';
        };

        subtest 'PUTSPREAD' => sub {
            $args->{bet_type} = 'PUTSPREAD';
            $c = produce_contract($args);
            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(0);
            BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration(900);     # 15 minutes
            ok $c->is_valid_to_sell, 'is valid to sell';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(1);
            $c = produce_contract($args);
            ok !$c->is_valid_to_sell, 'is invalid to sell';
            is $c->primary_validation_error->message,                'early sellback disabled for call/put Spreads';
            is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(0);
            BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration(1500);    # 25 minutes
            $c = produce_contract($args);
            ok !$c->is_valid_to_sell, 'is invalid to sell';
            is $c->primary_validation_error->message,                'remaing contract duration should be more than 1500 seconds for sellback';
            is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';
        };
    };
    subtest 'Forex' => sub {
        $args->{underlying} = 'frxAUDUSD';

        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch + 1,   $args->{underlying}],
            [100, $now->epoch + 300, $args->{underlying}],
            [100, $now->epoch + 400, $args->{underlying}]);

        subtest 'CALLSPREAD' => sub {
            my $c = produce_contract($args);
            ok !$c->is_expired, 'contract is not expired';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(0);
            BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration(900);    #15 minutes
            $c = produce_contract($args);
            ok $c->is_valid_to_sell, 'is valid to sell';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(1);
            $c = produce_contract($args);
            ok !$c->is_valid_to_sell, 'is invalid to sell';
            is $c->primary_validation_error->message,                'early sellback disabled for call/put Spreads';
            is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(0);
            BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration(1500);    # 25 minutes
            $c = produce_contract($args);
            ok !$c->is_valid_to_sell, 'is invalid to sell';
            is $c->primary_validation_error->message,                'remaing contract duration should be more than 1500 seconds for sellback';
            is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration(1800);    # 30 minutes
            $c = produce_contract($args);
            ok !$c->is_valid_to_sell, 'is invalid to sell';
            is $c->primary_validation_error->message,                'remaing contract duration should be more than 1800 seconds for sellback';
            is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';
        };
        subtest 'PUTSPREAD' => sub {
            $args->{bet_type} = 'PUTSPREAD';
            $c = produce_contract($args);
            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(0);
            BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration(900);     # 15 minutes
            ok $c->is_valid_to_sell, 'is valid to sell';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(1);
            $c = produce_contract($args);
            ok !$c->is_valid_to_sell, 'is invalid to sell';
            is $c->primary_validation_error->message,                'early sellback disabled for call/put Spreads';
            is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';

            BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback(0);
            BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration(1500);    # 25 minutes
            $c = produce_contract($args);
            ok !$c->is_valid_to_sell, 'is invalid to sell';
            is $c->primary_validation_error->message,                'remaing contract duration should be more than 1500 seconds for sellback';
            is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';
        };
    };

    BOM::Config::Runtime->instance->app_config->quants->callputspreads->disable_sellback($original_disable_sellback);
    BOM::Config::Runtime->instance->app_config->quants->callputspreads->minimum_allowed_sellback_duration($original_min_duration);
    BOM::Config::Runtime->instance->app_config->quants->markets->suspend_early_sellback($original_suspend_markets);
    BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_early_sellback($original_suspend_underlyings);
    BOM::Config::Runtime->instance->app_config->quants->contract_types->suspend_early_sellback($original_suspend_contract_type);
};

done_testing();
