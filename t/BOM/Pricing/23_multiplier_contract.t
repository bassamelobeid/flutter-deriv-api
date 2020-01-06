#!perl
use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use Data::Dumper;
use BOM::MarketData qw(create_underlying);
use Data::UUID;
use Date::Utility;

use BOM::Pricing::v3::Contract;
use BOM::Platform::Context qw (request);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Product::ContractFactory qw( produce_contract );

my $now             = Date::Utility->new;
my $landing_company = 'svg';

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);

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

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
request(BOM::Platform::Context::Request->new(params => {}));

subtest 'multiplier - send_ask' => sub {
    my $args = {
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "payout",
        "contract_type" => "MULTUP",
        "currency"      => "USD",
        "symbol"        => "R_100",
        "multiplier"    => 10,
    };
    my $params = {
        client_ip => '127.0.0.1',
        args      => $args,
    };

    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')->error_message_is('Basis must be stake for this contract.');

    $args->{basis} = 'stake';
    delete $args->{multiplier};

    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')
        ->error_message_is('Missing required contract parameters (multiplier).');

    $args->{multiplier}    = 10;
    $args->{duration_unit} = 'm';
    $args->{duration}      = 5;

    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')
        ->error_message_is('Invalid input (duration or date_expiry) for this contract type (MULTUP).');

    delete $args->{duration_unit};
    delete $args->{duration};

    my $expected = {
        'longcode'            => 'Win 10% of your stake for every 1% rise in the market price.',
        'spot'                => '100.00',
        'date_start'          => ignore(),
        'contract_parameters' => {
            'min_commission_amount' => '0.02',
            'app_markup_percentage' => 0,
            'amount_type'           => 'stake',
            'multiplier'            => 10,
            'currency'              => 'USD',
            'deep_otm_threshold'    => '0.025',
            'date_start'            => 0,
            'proposal'              => 1,
            'amount'                => '100',
            'base_commission'       => '0.012',
            'underlying'            => 'R_100',
            'bet_type'              => 'MULTUP'
        },
        'auth_time'     => ignore(),
        'display_value' => '100.00',
        'stash'         => {
            'source_bypass_verification' => 0,
            'valid_source'               => 1,
            'app_markup_percentage'      => '0'
        },
        'commission'  => '0.0504',
        'spot_time'   => ignore(),
        'limit_order' => {
            'stop_out' => {
                'value'        => '90.05',
                'display_name' => 'Stop Out',
                'order_date'   => ignore(),
                'order_amount' => -100
            }
        },
        'payout'     => '0',
        'rpc_time'   => ignore(),
        'ask_price'  => '100.00',
        'multiplier' => 10
    };
    my $res = $c->call_ok('send_ask', $params)->has_no_error->result;
    cmp_deeply($res, $expected, 'send_ask output as expected');

    $expected = {
        'longcode'            => 'Win 10% of your stake for every 1% rise in the market price.',
        'spot'                => '100.00',
        'date_start'          => ignore(),
        'contract_parameters' => {
            'min_commission_amount' => '0.02',
            'app_markup_percentage' => 0,
            'amount_type'           => 'stake',
            'multiplier'            => 10,
            'currency'              => 'USD',
            'deep_otm_threshold'    => '0.025',
            'limit_order'           => {'take_profit' => 10},
            'date_start'            => 0,
            'proposal'              => 1,
            'amount'                => '100',
            'base_commission'       => '0.012',
            'underlying'            => 'R_100',
            'bet_type'              => 'MULTUP'
        },
        'auth_time'     => ignore(),
        'display_value' => '100.00',
        'stash'         => {
            'source_bypass_verification' => 0,
            'valid_source'               => 1,
            'app_markup_percentage'      => '0'
        },
        'commission'  => '0.0504',
        'spot_time'   => ignore(),
        'limit_order' => {
            'stop_out' => {
                'value'        => '90.05',
                'display_name' => 'Stop Out',
                'order_date'   => ignore(),
                'order_amount' => -100
            },
            'take_profit' => {
                'display_name' => 'Take Profit',
                'order_amount' => 10,
                'order_date'   => ignore(),
                'value'        => 101.05,
            },
        },
        'payout'     => '0',
        'rpc_time'   => ignore(),
        'ask_price'  => '100.00',
        'multiplier' => 10
    };
    $args->{limit_order}->{take_profit} = 10;
    $res = $c->call_ok('send_ask', $params)->has_no_error->result;
    cmp_deeply($res, $expected, 'send_ask output as expected');

    $expected = {
        'longcode'            => 'Win 10% of your stake for every 1% rise in the market price.',
        'spot'                => '100.00',
        'date_start'          => ignore(),
        'contract_parameters' => {
            'min_commission_amount' => '0.02',
            'app_markup_percentage' => 0,
            'amount_type'           => 'stake',
            'multiplier'            => 10,
            'currency'              => 'USD',
            'deep_otm_threshold'    => '0.025',
            'deal_cancellation'     => 1,
            'limit_order'           => {'take_profit' => 10},
            'date_start'            => 0,
            'proposal'              => 1,
            'amount'                => '100',
            'base_commission'       => '0.012',
            'underlying'            => 'R_100',
            'bet_type'              => 'MULTUP'
        },
        'auth_time'     => ignore(),
        'display_value' => '104.35',
        'stash'         => {
            'source_bypass_verification' => 0,
            'valid_source'               => 1,
            'app_markup_percentage'      => '0'
        },
        'commission'  => '0.0504',
        'spot_time'   => ignore(),
        'limit_order' => {
            'stop_out' => {
                'value'        => '90.05',
                'display_name' => 'Stop Out',
                'order_date'   => ignore(),
                'order_amount' => -100
            },
            'take_profit' => {
                'display_name' => 'Take Profit',
                'order_amount' => 10,
                'order_date'   => ignore(),
                'value'        => 101.05,
            },
        },
        'payout'            => '0',
        'rpc_time'          => ignore(),
        'ask_price'         => '104.35',
        'multiplier'        => 10,
        'deal_cancellation' => {
            'ask_price'   => 4.35,
            'date_expiry' => ignore(),
        },
    };
    $args->{deal_cancellation} = 1;
    $res = $c->call_ok('send_ask', $params)->has_no_error->result;
    cmp_deeply($res, $expected, 'send_ask output as expected');
};

subtest 'multiplier - get_bid' => sub {
    my $contract = produce_contract({
            bet_type     => 'MULTUP',
            underlying   => 'R_100',
            multiplier   => 10,
            currency     => 'USD',
            amount_type  => 'stake',
            amount       => 100,
            date_start   => $now,
            date_pricing => $now->epoch + 1,
            limit_order  => {
                stop_out => {
                    order_type   => 'stop_out',
                    order_amount => -100,
                    order_date   => $now->epoch,
                    basis_spot   => 100
                }}});
    my $params = {
        short_code      => $contract->shortcode,
        contract_id     => $contract->id,
        currency        => 'USD',
        is_sold         => 0,
        country_code    => 'cr',
        landing_company => 'svg',
        limit_order     => $contract->available_orders,
    };

    my $expected = {
        'entry_tick_time'            => ignore(),
        'current_spot_display_value' => '100.00',
        'stash'                      => {
            'app_markup_percentage'      => '0',
            'source_bypass_verification' => 0,
            'valid_source'               => 1
        },
        'barrier_count'          => 1,
        'entry_tick'             => 100,
        'date_settlement'        => ignore(),
        'underlying'             => 'R_100',
        'contract_type'          => 'MULTUP',
        'is_path_dependent'      => '1',
        'multiplier'             => '10',
        'current_spot_time'      => ignore(),
        'date_expiry'            => ignore(),
        'entry_spot'             => 100,
        'currency'               => 'USD',
        'limit_order'            => ['stop_out', ['basis_spot', 100, 'order_amount', '-100.00', 'order_date', ignore(), 'order_type', 'stop_out']],
        'limit_order_as_hashref' => {
            'stop_out' => {
                'order_amount' => '-100.00',
                'order_date'   => ignore(),
                'display_name' => 'Stop Out',
                'value'        => '90.05'
            }
        },
        'display_name'             => 'Volatility 100 Index',
        'is_settleable'            => 0,
        'is_intraday'              => 0,
        'entry_tick_display_value' => '100.00',
        'is_expired'               => 0,
        'is_forward_starting'      => 0,
        'bid_price'                => '99.50',
        'shortcode'                => ignore(),
        'contract_id'              => '470',
        'longcode'                 => 'Win 10% of your stake for every 1% rise in the market price.',
        'is_valid_to_sell'         => 1,
        'is_valid_to_cancel'       => 0,
        'entry_spot_display_value' => '100.00',
        'commission'               => '0.50',
        'current_spot'             => 100,
        'date_start'               => $now->epoch,
        'status'                   => 'open'
    };
    my $res = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply($res, $expected, 'get_bid as expected');

    $contract = produce_contract({
            bet_type     => 'MULTUP',
            underlying   => 'R_100',
            multiplier   => 10,
            currency     => 'USD',
            amount_type  => 'stake',
            amount       => 100,
            date_start   => $now,
            date_pricing => $now->epoch + 1,
            limit_order  => {
                stop_out => {
                    order_type   => 'stop_out',
                    order_amount => -100,
                    order_date   => $now->epoch,
                    basis_spot   => 100
                }
            },
            deal_cancellation => 1,
        });
    $params = {
        short_code      => $contract->shortcode,
        contract_id     => $contract->id,
        currency        => 'USD',
        is_sold         => 0,
        country_code    => 'cr',
        landing_company => 'svg',
        limit_order     => $contract->available_orders,
    };

    $expected = {
        'entry_tick_time'            => ignore(),
        'current_spot_display_value' => '100.00',
        'stash'                      => {
            'app_markup_percentage'      => '0',
            'source_bypass_verification' => 0,
            'valid_source'               => 1
        },
        'barrier_count'          => 1,
        'entry_tick'             => 100,
        'date_settlement'        => ignore(),
        'underlying'             => 'R_100',
        'contract_type'          => 'MULTUP',
        'is_path_dependent'      => '1',
        'multiplier'             => '10',
        'current_spot_time'      => ignore(),
        'date_expiry'            => ignore(),
        'entry_spot'             => 100,
        'currency'               => 'USD',
        'limit_order'            => ['stop_out', ['basis_spot', 100, 'order_amount', '-100.00', 'order_date', ignore(), 'order_type', 'stop_out']],
        'limit_order_as_hashref' => {
            'stop_out' => {
                'order_amount' => '-100.00',
                'order_date'   => ignore(),
                'display_name' => 'Stop Out',
                'value'        => '90.05'
            }
        },
        'display_name'             => 'Volatility 100 Index',
        'is_settleable'            => 0,
        'is_intraday'              => 0,
        'entry_tick_display_value' => '100.00',
        'is_expired'               => 0,
        'is_forward_starting'      => 0,
        'bid_price'                => '99.50',
        'shortcode'                => ignore(),
        'contract_id'              => '470',
        'longcode'                 => 'Win 10% of your stake for every 1% rise in the market price.',
        'is_valid_to_sell'         => 0,
        'is_valid_to_cancel'       => 1,
        'entry_spot_display_value' => '100.00',
        'commission'               => '0.50',
        'current_spot'             => 100,
        'date_start'               => $now->epoch,
        'status'                   => 'open',
        'deal_cancellation'        => {
            'ask_price'   => 4.35,
            'date_expiry' => ignore(),
        },
        'validation_error' =>
            'If we close this contract now, you may lose your stake. Alternatively, you may cancel this contract and you’ll get your stake back without any loss or profit.',
    };
    $res = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply($res, $expected, 'get_bid as expected');
};

done_testing();
