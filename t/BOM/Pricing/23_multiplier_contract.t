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

done_testing();
