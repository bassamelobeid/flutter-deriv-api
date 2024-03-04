#!perl
use strict;
use warnings;

use BOM::Platform::Context                       qw(request);
use BOM::Product::ContractFactory                qw(produce_contract);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::RPC::QueueClient;
use Date::Utility;
use Test::MockModule;
use Test::Mojo;
use Test::Most;

my $now             = Date::Utility->new;
my $landing_company = 'svg';

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [100, $now->epoch + 1, 'R_100']);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol        => 'R_100',
        recorded_date => $now
    });

my $c = BOM::Test::RPC::QueueClient->new();
request(BOM::Platform::Context::Request->new(params => {}));

subtest 'accumulator - send_ask' => sub {
    my $args = {
        "proposal"      => 1,
        "amount"        => 100,
        "basis"         => "payout",
        "contract_type" => "ACCU",
        "currency"      => "USD",
        "growth_rate"   => 0.01,
        "symbol"        => "R_100"
    };
    my $params = {
        client_ip => '127.0.0.1',
        args      => $args,
    };

    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')->error_message_is('Basis must be stake for this contract.');

    $args->{basis} = 'stake';
    delete $args->{growth_rate};

    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')
        ->error_message_is('Missing required contract parameters (growth_rate).');

    $args->{growth_rate}   = 0.01;
    $args->{duration_unit} = 'm';
    $args->{duration}      = 5;

    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')
        ->error_message_is('Invalid input (duration or date_expiry) for this contract type (ACCU).');

    delete $args->{duration_unit};
    delete $args->{duration};

    my $expected = {
        'ask_price'        => '100.00',
        'auth_time'        => ignore(),
        "contract_details" => {
            "barrier_spot_distance" => 0.065,
            "high_barrier"          => 100.065,
            "last_tick_epoch"       => 123123123,
            "low_barrier"           => 99.935,
            "maximum_payout"        => ignore(),
            "maximum_stake"         => '2000.00',
            "maximum_ticks"         => ignore(),
            "minimum_stake"         => '1.00',
            "tick_size_barrier"     => 0.000644417416,
        },
        'contract_parameters' => {
            'amount'                => '100',
            'amount_type'           => 'stake',
            'app_markup_percentage' => 0,
            'base_commission'       => '0',
            'bet_type'              => 'ACCU',
            'currency'              => 'USD',
            'date_start'            => 0,
            'deep_otm_threshold'    => '0.025',
            'growth_rate'           => 0.01,
            'landing_company'       => 'virtual',
            'min_commission_amount' => '0.02',
            'proposal'              => 1,
            'underlying'            => 'R_100',
        },
        'date_expiry'   => ignore(),
        'date_start'    => ignore(),
        'display_value' => '100.00',
        'longcode'      => ignore(),
        'stash'         => {
            'app_markup_percentage'      => '0',
            'market'                     => 'synthetic_index',
            'source_bypass_verification' => 0,
            'source_type'                => 'official',
            'valid_source'               => 1,
        },
        'spot'         => '100.00',
        'spot_time'    => ignore(),
        'payout'       => '0',
        'rpc_time'     => ignore(),
        skip_streaming => 0,
        channel        =>
            'PRICER_ARGS::["amount","100","basis","stake","contract_type","ACCU","country_code",null,"currency","USD","growth_rate","0.01","landing_company","virtual","price_daemon_cmd","price","proposal","1","skips_price_validation","1","symbol","R_100"]',
        subchannel           => 'v1,USD,100,stake,0,0.025,0,0.02,,,,,EN',
        subscription_channel =>
            'PRICER_ARGS::["amount","100","basis","stake","contract_type","ACCU","country_code",null,"currency","USD","growth_rate","0.01","landing_company","virtual","price_daemon_cmd","price","proposal","1","skips_price_validation","1","symbol","R_100"]::v1,USD,100,stake,0,0.025,0,0.02,,,,,EN'
    };
    my $redis_mock = Test::MockModule->new('RedisDB');
    $redis_mock->mock(
        'hget',
        sub {
            my ($self, @args) = @_;
            return '{"tick_epoch":"123123123"}';
        });

    my $res = $c->call_ok('send_ask', $params)->has_no_error->result;
    cmp_deeply($res, $expected, 'send_ask output as expected');

    $expected = {
        'ask_price'        => '100.00',
        'auth_time'        => ignore(),
        "contract_details" => {
            "barrier_spot_distance" => 0.065,
            "high_barrier"          => 100.065,
            "last_tick_epoch"       => 123123123,
            "low_barrier"           => 99.935,
            "maximum_payout"        => ignore(),
            "maximum_stake"         => '2000.00',
            "maximum_ticks"         => ignore(),
            "minimum_stake"         => '1.00',
            "tick_size_barrier"     => 0.000644417416,
        },
        'contract_parameters' => {
            'amount'                => '100',
            'amount_type'           => 'stake',
            'app_markup_percentage' => 0,
            'base_commission'       => '0',
            'bet_type'              => 'ACCU',
            'currency'              => 'USD',
            'date_start'            => 0,
            'deep_otm_threshold'    => '0.025',
            'growth_rate'           => 0.01,
            'landing_company'       => 'virtual',
            'limit_order'           => {'take_profit' => 10},
            'min_commission_amount' => '0.02',
            'proposal'              => 1,
            'underlying'            => 'R_100',
        },
        'date_expiry'   => ignore(),
        'date_start'    => ignore(),
        'display_value' => '100.00',
        'limit_order'   => {
            'take_profit' => {
                'display_name' => 'Take profit',
                'order_amount' => 10,
                'order_date'   => ignore()
            },
        },
        'longcode' => ignore(),
        'stash'    => {
            'app_markup_percentage'      => '0',
            'market'                     => 'synthetic_index',
            'source_bypass_verification' => 0,
            'source_type'                => 'official',
            'valid_source'               => 1,
        },
        'spot'         => '100.00',
        'spot_time'    => ignore(),
        'payout'       => '0',
        'rpc_time'     => ignore(),
        skip_streaming => 0,
        channel        =>
            'PRICER_ARGS::["amount","100","basis","stake","contract_type","ACCU","country_code",null,"currency","USD","growth_rate","0.01","landing_company","virtual","limit_order",{"take_profit":10},"price_daemon_cmd","price","proposal","1","skips_price_validation","1","symbol","R_100"]',
        subchannel           => 'v1,USD,100,stake,0,0.025,0,0.02,,,,,EN',
        subscription_channel =>
            'PRICER_ARGS::["amount","100","basis","stake","contract_type","ACCU","country_code",null,"currency","USD","growth_rate","0.01","landing_company","virtual","limit_order",{"take_profit":10},"price_daemon_cmd","price","proposal","1","skips_price_validation","1","symbol","R_100"]::v1,USD,100,stake,0,0.025,0,0.02,,,,,EN'
    };

    $args->{limit_order}->{take_profit} = 10;
    $res = $c->call_ok('send_ask', $params)->has_no_error->result;
    cmp_deeply($res, $expected, 'send_ask output as expected');

    $args->{limit_order}->{stop_loss} = 10;
    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')
        ->error_message_is('stop_loss is not a valid input for contract type ACCU.');
};

subtest 'accumulator - get_bid' => sub {
    my $contract = produce_contract({
            bet_type          => 'ACCU',
            underlying        => 'R_100',
            growth_rate       => 0.01,
            currency          => 'USD',
            amount_type       => 'stake',
            amount            => 100,
            date_start        => $now,
            date_pricing      => $now->epoch + 1,
            tick_size_barrier => '0.02751',
            limit_order       => {
                take_profit => {
                    order_type   => 'take_profit',
                    order_amount => 100,
                    order_date   => $now->epoch
                }}});
    my $params = {
        short_code      => $contract->shortcode,
        contract_id     => $contract->id,
        currency        => 'USD',
        is_sold         => 0,
        country_code    => 'cr',
        landing_company => 'virtual',
        limit_order     => $contract->available_orders,
    };

    my $expected = {
        'is_sold'                    => 0,
        'entry_tick_time'            => ignore(),
        'current_spot_display_value' => '100.00',
        'stash'                      => {
            'app_markup_percentage'      => '0',
            'source_bypass_verification' => 0,
            'valid_source'               => 1,
            source_type                  => 'official',
        },
        'barrier_count'     => 2,
        'entry_tick'        => 100,
        'date_settlement'   => ignore(),
        'underlying'        => 'R_100',
        'contract_type'     => 'ACCU',
        'is_path_dependent' => '1',
        'growth_rate'       => '0.01',
        'current_spot_time' => ignore(),
        'date_expiry'       => ignore(),
        'entry_spot'        => 100,
        'currency'          => 'USD',
        'limit_order'       => {
            take_profit => {
                display_name => "Take profit",
                order_amount => "100.00",
                order_date   => ignore()
            },
        },
        'display_name'              => 'Volatility 100 Index',
        'is_settleable'             => 0,
        'is_intraday'               => 0,
        'entry_tick_display_value'  => '100.00',
        'is_expired'                => 0,
        'is_forward_starting'       => 0,
        'bid_price'                 => '100.00',
        'shortcode'                 => ignore(),
        'contract_id'               => '490',
        'longcode'                  => ignore(),
        'is_valid_to_sell'          => 0,
        'is_valid_to_cancel'        => 0,
        'entry_spot_display_value'  => '100.00',
        'current_spot'              => 100,
        'date_start'                => $now->epoch,
        'status'                    => 'open',
        'expiry_time'               => ignore(),
        'tick_count'                => ignore(),
        'tick_passed'               => 0,
        'tick_stream'               => ignore(),
        'validation_error'          => 'Contract cannot be sold at entry tick. Please wait for the next tick.',
        'validation_error_code'     => 'General',
        'current_spot_high_barrier' => 102.751,
        'current_spot_low_barrier'  => 97.249,
        'barrier_spot_distance'     => 2.751,
    };
    my $res = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply($res, $expected, 'get_bid as expected');
};

done_testing();
