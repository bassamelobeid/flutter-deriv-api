#!perl
use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use Test::Warnings qw(warning warnings);
use Test::MockModule;
use Test::MockTime::HiRes;
use Date::Utility;

use Data::Dumper;
use Quant::Framework::Utils::Test;
use Quant::Framework::CorporateAction;
use Quant::Framework::StorageAccessor;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::RPC::v3::Contract;
use BOM::Platform::Context qw (request);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Platform::RedisReplicated;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Database::Model::OAuth;

initialize_realtime_ticks_db();
my $now   = Date::Utility->new('2005-09-21 06:46:00');
my $email = 'test@binary.com';

my $storage_accessor = Quant::Framework::StorageAccessor->new(
    chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
    chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
$client->deposit_virtual_funds;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD AUD CAD-AUD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw (frxAUDCAD frxUSDCAD frxAUDUSD);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
request(BOM::Platform::Context::Request->new(params => {}));

subtest 'validate_symbol' => sub {
    is(BOM::RPC::v3::Contract::validate_symbol('R_50'), undef, "return undef if symbol is valid");
    cmp_deeply(
        BOM::RPC::v3::Contract::validate_symbol('invalid_symbol'),
        {
            'error' => {
                'message' => 'Symbol [_1] invalid',
                'code'    => 'InvalidSymbol',
                params    => [qw/ invalid_symbol /],
            }
        },
        'return error if symbol is invalid'
    );
};

subtest 'validate_license' => sub {
    is(BOM::RPC::v3::Contract::validate_license('R_50'), undef, "return undef if symbol is realtime");

    cmp_deeply(
        BOM::RPC::v3::Contract::validate_license('JCI'),
        {
            error => {
                message => 'Realtime quotes not available for [_1]',
                code    => 'NoRealtimeQuotes',
                params  => [qw/ JCI /],
            }
        },
        "return error if symbol is not realtime"
    );
};

subtest 'validate_is_open' => sub {

    # weekend
    set_fixed_time(Date::Utility->new('2016-07-23')->epoch);

    is(BOM::RPC::v3::Contract::validate_is_open('R_50'), undef, "Random is always open");

    cmp_deeply(
        BOM::RPC::v3::Contract::validate_is_open('frxUSDJPY'),
        {
            error => {
                message => 'This market is presently closed.',
                code    => 'MarketIsClosed',
                params  => [qw/ frxUSDJPY /],
            }
        },
        "return error if market is not open"
    );
    set_fixed_time(Date::Utility->new()->epoch);
};

subtest 'validate_underlying' => sub {
    cmp_deeply(
        BOM::RPC::v3::Contract::validate_underlying('invalid_symbol'),
        {
            'error' => {
                'message' => 'Symbol [_1] invalid',
                'code'    => 'InvalidSymbol',
                params    => [qw/ invalid_symbol /],
            }
        },
        'return error if symbol is invalid'
    );

    cmp_deeply(
        BOM::RPC::v3::Contract::validate_underlying('JCI'),
        {
            error => {
                message => 'Realtime quotes not available for [_1]',
                code    => 'NoRealtimeQuotes',
                params  => [qw/ JCI /],
            }
        },
        "return error if symbol is not realtime"
    );

    set_fixed_time(Date::Utility->new('2016-07-24')->epoch);
    cmp_deeply(
        BOM::RPC::v3::Contract::validate_is_open('frxUSDJPY'),
        {
            error => {
                message => 'This market is presently closed.',
                code    => 'MarketIsClosed',
                params  => [qw/ frxUSDJPY /],
            }
        },
        "return error if market is not open"
    );
    set_fixed_time(Date::Utility->new()->epoch);

    cmp_deeply(BOM::RPC::v3::Contract::validate_underlying('R_50'), {status => 1}, 'status 1 if everything ok');
};

subtest 'prepare_ask' => sub {
    my $params = {
        "proposal"      => 1,
        "subscribe"     => 1,
        "amount"        => "2",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "2",
        "duration_unit" => "m"
    };
    my $expected = {
        'barrier'     => 'S0P',
        'subscribe'   => 1,
        'duration'    => '2m',
        'amount_type' => 'payout',
        'bet_type'    => 'CALL',
        'underlying'  => 'R_50',
        'currency'    => 'USD',
        'amount'      => '2',
        'proposal'    => 1,
        'date_start'  => 0
    };
    cmp_deeply(BOM::RPC::v3::Contract::prepare_ask($params), $expected, 'prepare_ask result ok');
    $params = {
        %$params,
        date_expiry => '2015-01-01',
        barrier     => 'S0P',
        barrier2    => 'S1P',
    };
    $expected = {
        %$expected,
        fixed_expiry  => 1,
        high_barrier  => 'S0P',
        low_barrier   => 'S1P',
        date_expiry   => '2015-01-01',
        duration_unit => 'm',
        duration      => '2',
    };
    delete $expected->{barrier};
    delete $expected->{barrier2};
    cmp_deeply(BOM::RPC::v3::Contract::prepare_ask($params), $expected, 'result is ok after added date_expiry and barrier and barrier2');

    delete $params->{barrier};
    $expected->{barrier} = 'S0P';
    delete $expected->{high_barrier};
    delete $expected->{low_barrier};
    cmp_deeply(BOM::RPC::v3::Contract::prepare_ask($params),
        $expected, 'will set barrier default value and delete barrier2 if contract type is not like SPREAD and ASIAN');

    delete $expected->{barrier};
    $expected->{barrier2} = 'S1P';
    for my $t (qw(SPREAD ASIAN)) {
        $params->{contract_type} = $t;
        $expected->{bet_type}    = $t;
        cmp_deeply(BOM::RPC::v3::Contract::prepare_ask($params), $expected, 'will not set barrier if contract type is like SPREAD and ASIAN ');

    }

};

subtest 'get_ask' => sub {
    my $params = {
        "proposal"         => 1,
        "amount"           => "100",
        "basis"            => "payout",
        "contract_type"    => "CALL",
        "currency"         => "USD",
        "duration"         => "60",
        "duration_unit"    => "s",
        "symbol"           => "R_50",
        "streaming_params" => {add_theo_probability => 1},
    };
    my $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params));
    ok(delete $result->{spot_time},  'result have spot time');
    ok(delete $result->{date_start}, 'result have date_start');
    my $expected = {
        'display_value'       => '51.49',
        'ask_price'           => '51.49',
        'longcode'            => 'Win payout if Volatility 50 Index is strictly higher than entry spot at 1 minute after contract start time.',
        'spot'                => '963.3054',
        'payout'              => '100',
        'theo_probability'    => 0.499862404631018,
        'contract_parameters' => {
            'deep_otm_threshold'         => '0.025',
            'barrier'                    => 'S0P',
            'duration'                   => '60s',
            'bet_type'                   => 'CALL',
            'amount_type'                => 'payout',
            'underlying'                 => 'R_50',
            'currency'                   => 'USD',
            'underlying_base_commission' => '0.015',
            'amount'                     => '100',
            'base_commission_scaling'    => 100,
            'app_markup_percentage'      => 0,
            'proposal'                   => 1,
            date_start                   => ignore(),
            'staking_limits'             => {
                'message_to_client'       => 'Minimum stake of 0.35 and maximum payout of 50,000.00',
                'min'                     => '0.35',
                'max'                     => 50000,
                'message_to_client_array' => ['Minimum stake of [_1] and maximum payout of [_2]', '0.35', '50,000.00']}}};
    cmp_deeply($result, $expected, 'the left values are all right');

    $params->{symbol} = "invalid symbol";
    cmp_deeply([
            warnings {
                cmp_deeply(
                    BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params)),
                    {
                        error => {
                            message_to_client => 'Cannot create contract',
                            code              => "ContractCreationFailure",
                        }
                    },
                    'ContractCreationFailure with invalid symbol'
                );
            }
        ],
        bag(re('Could not load volsurface for invalid symbol')),
        'had warning about volsurface for invalid symbol'
    );

    cmp_deeply([
            warnings {
                cmp_deeply(
                    BOM::RPC::v3::Contract::_get_ask({}),
                    {
                        error => {
                            message_to_client => 'Cannot create contract',
                            code              => "ContractCreationFailure",
                        }
                    },
                    'ContractCreationFailure with empty parameters'
                );
            }
        ],
        bag(re('_get_ask produce_contract failed')),
        'empty params for _get_ask required warning'
    );

};

subtest 'get_ask_when_date_expiry_smaller_than_date_start' => sub {
    my $params = {
        'proposal'         => 1,
        'fixed_expiry'     => 1,
        'date_expiry'      => '1476670200',
        'contract_type'    => 'PUT',
        'basis'            => 'payout',
        'currency'         => 'USD',
        'symbol'           => 'R_50',
        'amount'           => '100',
        'duration_unit'    => 'm',
        'date_start'       => '1476676000',
        "streaming_params" => {add_theo_probability => 1},
    };
    my $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params));
    my $expected = {
        error => {
            'code'              => 'ContractCreationFailure',
            'message_to_client' => 'Cannot create contract',
        }};
    cmp_deeply($result, $expected, 'errors response is correct when date_expiry < date_start with payout_type is payout');

    $params = {
        'proposal'         => 1,
        'fixed_expiry'     => 1,
        'date_expiry'      => '1476670200',
        'contract_type'    => 'PUT',
        'basis'            => 'stake',
        'currency'         => 'USD',
        'symbol'           => 'R_50',
        'amount'           => '10',
        'duration_unit'    => 'm',
        'date_start'       => '1476676000',
        "streaming_params" => {add_theo_probability => 1},
    };
    $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params));
    $expected = {
        error => {
            'code'              => 'ContractCreationFailure',
            'message_to_client' => 'Cannot create contract',
        }};

    cmp_deeply($result, $expected, 'errors response is correct when date_expiry < date_start with payout_type is stake');
    $params = {
        'proposal'         => 1,
        'fixed_expiry'     => 1,
        'date_expiry'      => '1476670200',
        'contract_type'    => 'PUT',
        'basis'            => 'stake',
        'currency'         => 'USD',
        'symbol'           => 'R_50',
        'amount'           => '11',
        'duration_unit'    => 'm',
        'date_start'       => '1476670200',
        "streaming_params" => {add_theo_probability => 1},
    };
    $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params));
    $expected = {
        error => {
            'code'              => 'ContractCreationFailure',
            'message_to_client' => 'Cannot create contract',
        }};

    cmp_deeply($result, $expected, 'errors response is correct when date_expiry = date_start with payout_type is stake');

};

subtest 'send_ask' => sub {
    my $params = {
        client_ip => '127.0.0.1',
        args      => {
            "proposal"         => 1,
            "amount"           => "100",
            "basis"            => "payout",
            "contract_type"    => "CALL",
            "currency"         => "USD",
            "duration"         => "60",
            "duration_unit"    => "s",
            "symbol"           => "R_50",
            "streaming_params" => {add_theo_probability => 1},
        }};

    my $result = $c->call_ok('send_ask', $params)->has_no_error->result;
    my $expected_keys =
        [sort { $a cmp $b } (qw(longcode spot display_value ask_price spot_time date_start rpc_time payout theo_probability contract_parameters))];
    cmp_deeply([sort keys %$result], $expected_keys, 'result keys is correct');
    is(
        $result->{longcode},
        'Win payout if Volatility 50 Index is strictly higher than entry spot at 1 minute after contract start time.',
        'long code  is correct'
    );
    {
        cmp_deeply([
                warnings {
                    $c->call_ok('send_ask', {args => {symbol => 'R_50'}})->has_error->error_code_is('ContractCreationFailure')
                        ->error_message_is('Cannot create contract');
                }
            ],
            bag(re('Use of uninitialized value in pattern match'), re('_get_ask produce_contract failed')),
            'missing bet_type when checking contract_type'
        );

        my $mock_contract = Test::MockModule->new('BOM::RPC::v3::Contract');
        $mock_contract->mock('_get_ask', sub { die "mock _get_ask dying on purpose" });
        cmp_deeply([
                warnings {
                    $c->call_ok('send_ask', {args => {symbol => 'R_50'}})->has_error->error_code_is('pricing error')
                        ->error_message_is('Unable to price the contract.');
                }
            ],
            bag(re('mock _get_ask dying'), re('Use of uninitialized value in pattern match'),),
            'have expected warnings when _get_ask dies'
        );
    }
};

subtest 'send_ask_when_date_expiry_smaller_than_date_start' => sub {
    my $params = {
        client_ip => '127.0.0.1',
        args      => {
            'proposal'      => 1,
            'fixed_expiry'  => 1,
            'date_expiry'   => '1476670200',
            'contract_type' => 'PUT',
            'basis'         => 'payout',
            'currency'      => 'USD',
            'symbol'        => 'R_50',
            'amount'        => '100',
            'duration_unit' => 'm',
            'date_start'    => '1476676000',

            "streaming_params" => {add_theo_probability => 1},
        }};
    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')->error_message_is('Cannot create contract');
    
};

subtest 'send_multiple_ask' => sub {
    my $params = {
        client_ip => '127.0.0.1',
        args      => {
            "amount"        => "100",
            "basis"         => "payout",
            "contract_type" => "DIGITMATCH",
            "currency"      => "USD",
            "duration"      => "10",
            "duration_unit" => "t",
            "symbol"        => "R_50",
            "barriers"      => [{"barrier" => "3"}, {"barrier" => "2"}]}};
    use Data::Dumper;
    my $result = $c->call_ok('send_multiple_ask', $params)->has_no_error->result;
    my $outer_expected_keys = [sort (qw(rpc_time proposals))];
    cmp_deeply([sort keys %$result], $outer_expected_keys, 'result keys is correct');
    is(scalar(@{$result->{proposals}}), 2, "There are 2 proposals");
    my $inner_expected_keys = [sort (qw(longcode spot display_value spot_time ask_price date_start contract_parameters payout barrier))];
    for my $proposal (@{$result->{proposals}}) {
        cmp_deeply([sort keys %$proposal], $inner_expected_keys, 'result keys is correct in proposals');
    }

    $params->{args}{barriers}[0]{barrier} = "10";
    $result = $c->call_ok('send_multiple_ask', $params)->has_no_error->result;
    cmp_deeply([sort keys %$result], $outer_expected_keys, 'result keys is correct');
    is(scalar(@{$result->{proposals}}), 2, "There are 2 proposals");
    cmp_deeply([sort keys %{$result->{proposals}[0]}], [sort qw(error)], 'the first proposal has error');
    my $expected_error_keys = [sort qw(message_to_client details continue_price_stream code)];
    cmp_deeply([sort keys %{$result->{proposals}[0]{error}}], $expected_error_keys, "error keys ok");
    my $expected_details_keys = [sort qw(display_value payout barrier)];
    cmp_deeply([sort keys %{$result->{proposals}[0]{error}{details}}], $expected_details_keys, "details keys ok");
    my $proposal = $result->{proposals}[1];
    cmp_deeply([sort keys %$proposal], $inner_expected_keys, 'the second proposal still ok');
};

subtest 'get_bid' => sub {

    # just one tick for missing market data
    create_ticks([100, $now->epoch - 899, 'R_50']);
    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
    });

    my $contract = _create_contract(
        client        => $client,
        spread        => 0,
        current_tick  => $tick,
        date_start    => $now->epoch - 900,
        date_expiry   => $now->epoch - 500,
        purchase_date => $now->epoch - 901
    );
    my $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };
    $c->call_ok('get_bid', $params)->has_error->error_code_is('GetProposalFailure')
        ->error_message_is(
        'There was a market data disruption during the contract period. For real-money accounts we will attempt to correct this and settle the contract properly, otherwise the contract will be cancelled and refunded. Virtual-money contracts will be cancelled and refunded.'
        );

    $contract = _create_contract(
        client => $client,
        spread => 1
    );

    $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    my $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    my @expected_keys = (
        qw(bid_price
            current_spot_time
            contract_id
            underlying
            is_expired
            is_valid_to_sell
            is_forward_starting
            is_path_dependent
            is_intraday
            date_start
            date_expiry
            date_settlement
            currency
            longcode
            shortcode
            payout
            contract_type
            display_name
            stop_loss_level
            stop_profit_level
            entry_level
            exit_level
            current_value_in_dollar
            current_value_in_point
            amount_per_point
            ));
    cmp_bag([sort keys %{$result}], [sort @expected_keys]);

    $contract = _create_contract(
        client => $client,
        spread => 0
    );

    $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;

    @expected_keys = (qw(
            bid_price
            current_spot_time
            contract_id
            underlying
            is_expired
            is_valid_to_sell
            is_settleable
            is_forward_starting
            is_path_dependent
            is_intraday
            date_start
            date_expiry
            date_settlement
            currency
            longcode
            shortcode
            payout
            contract_type
            display_name
    ));

    push @expected_keys, qw(
        barrier
        exit_tick_time
        exit_tick
        entry_tick
        entry_tick_time
        current_spot
        entry_spot
        barrier_count
    );
    cmp_bag([sort keys %{$result}], [sort @expected_keys], 'keys of result is correct');

};

subtest 'get_bid_skip_barrier_validation' => sub {
    my ($contract, $params, $result);

    set_fixed_time($now->epoch);

    $contract = _create_contract(
        client       => $client,
        spread       => 0,
        date_expiry  => $now->epoch + 900,
        bet_type     => 'ONETOUCH',
        barrier      => 963.3055,
        date_pricing => $now->epoch - 100,
    );

    $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    like $result->{validation_error}, qr/^Barrier must be at least/, "Barrier error expected";

    $params->{validation_params} = {skip_barrier_validation => 1};
    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    ok(!exists $result->{validation_error}, "No barrier validation error")
        or diag "validatione error: " . ($result->{validation_error} // '<undef>');

    restore_time();
};

my $method = 'get_contract_details';
subtest $method => sub {
    my $params = {token => '12345'};
    $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'invalid token');
    $client->set_status('disabled', 1, 'test');
    $client->save;
    $params->{token} = $token;
    $c->call_ok($method, $params)->has_error->error_message_is('This account is unavailable.', 'invalid token');
    $client->clr_status('disabled');
    $client->save;

    cmp_deeply([
            warnings {
                $c->call_ok($method, $params)
                    ->has_error->error_message_is('Cannot create contract', 'will report error if no short_code and currency');
            }
        ],

        # We get several undef warnings too, but we'll ignore them for this test
        supersetof(re('get_contract_details produce_contract failed')),
        '... and had warning about failed produce_contract'
    );

    my $contract = _create_contract(
        client => $client,
        spread => 0
    );
    $params->{short_code} = $contract->shortcode;
    $params->{currency}   = 'USD';
    $c->call_ok($method, $params)->has_no_error->result_is_deeply({
            'symbol'       => 'R_50',
            'longcode'     => "Win payout if Volatility 50 Index is strictly higher than entry spot at 50 seconds after contract start time.",
            'display_name' => 'Volatility 50 Index',
            'date_expiry'  => $now->epoch - 50,
        },
        'result is ok'
    );
    create_ticks([0.9935, $now->epoch - 899, 'frxAUDCAD'], [0.9938, $now->epoch - 501, 'frxAUDCAD'], [0.9939, $now->epoch - 499, 'frxAUDCAD']);

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 0.9935,
        epoch      => $now->epoch,
        underlying => 'frxAUDCAD',
    });

    $contract = _create_contract(
        client        => $client,
        spread        => 0,
        underlying    => 'frxAUDCAD',
        current_tick  => $tick,
        date_start    => $now->epoch - 900,
        date_expiry   => $now->epoch - 500,
        purchase_date => $now->epoch - 901,
        date_pricing  => $now->epoch,
    );
    $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => 'USD',
    };
    my $res = $c->call_ok('get_bid', $params)->result;
    my $expected_result = {
        'barrier'         => '0.99350',
        'contract_id'     => 10,
        'currency'        => 'USD',
        'bid_price'       => '156.47',
        'payout'          => '156.47',
        'date_expiry'     => 1127287660,
        'date_settlement' => 1127287660,
        'date_start'      => 1127287260,
        'entry_spot'      => '0.99350',
        'entry_tick'      => '0.99350',
        'entry_tick_time' => 1127287261,
        'exit_tick'       => '0.99380',
        'exit_tick_time'  => 1127287659,
        'longcode'        => 'Win payout if AUD/CAD is strictly higher than entry spot at 6 minutes 40 seconds after contract start time.',
        'shortcode'       => 'CALL_FRXAUDCAD_156.47_1127287260_1127287660_S0P_0',
        'underlying'      => 'frxAUDCAD',
        is_valid_to_sell  => 1,
    };

    foreach my $key (keys %$expected_result) {
        cmp_ok $res->{$key}, 'eq', $expected_result->{$key}, "$key are matching ";
    }

    create_ticks([0.9936, $now->epoch - 499, 'frxAUDCAD'], [0.9938, $now->epoch - 100, 'frxAUDCAD'], [0.9934, $now->epoch - 99, 'frxAUDCAD']);

    $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 0.9935,
        epoch      => $now->epoch,
        underlying => 'frxAUDCAD',
    });

    $contract = _create_contract(
        client        => $client,
        spread        => 0,
        current_tick  => $tick,
        underlying    => 'frxAUDCAD',
        date_start    => $now->epoch - 500,
        date_expiry   => $now->epoch - 98,
        purchase_date => $now->epoch - 501,
        date_pricing  => $now->epoch,
    );
    $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => 'USD',
        is_sold     => 0,
    };
    $res = $c->call_ok('get_bid', $params)->result;
    $expected_result = {
        'barrier'         => '0.99360',
        'bid_price'       => '0.00',
        'is_expired'      => 1,
        'contract_id'     => 10,
        'currency'        => 'USD',
        'date_expiry'     => 1127288662,
        'date_settlement' => 1127288662,
        'date_start'      => 1127288260,
        'payout'          => '196.72',
        'entry_spot'      => '0.99360',
        'entry_tick'      => '0.99360',
        'entry_tick_time' => 1127288261,
        'exit_tick'       => '0.99340',
        'exit_tick_time'  => 1127288661,
        'longcode'        => 'Win payout if AUD/CAD is strictly higher than entry spot at 6 minutes 42 seconds after contract start time.',
        'shortcode'       => 'CALL_FRXAUDCAD_196.72_1127288260_1127288662_S0P_0',
        'underlying'      => 'frxAUDCAD',
        is_valid_to_sell  => 1,
    };

    foreach my $key (keys %$expected_result) {
        cmp_ok $res->{$key}, 'eq', $expected_result->{$key}, "$key are matching ";
    }

    $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => 'USD',
        is_sold     => 1,
    };
    $res = $c->call_ok('get_bid', $params)->result;
    $expected_result = {
        'barrier'         => '0.99360',
        'bid_price'       => '0.00',
        'is_expired'      => 1,
        'contract_id'     => 10,
        'currency'        => 'USD',
        'payout'          => '196.72',
        'date_expiry'     => 1127288662,
        'date_settlement' => 1127288662,
        'date_start'      => 1127288260,
        'entry_spot'      => '0.99360',
        'entry_tick'      => '0.99360',
        'entry_tick_time' => 1127288261,
        'exit_tick'       => '0.99340',
        'exit_tick_time'  => 1127288661,
        'longcode'        => 'Win payout if AUD/CAD is strictly higher than entry spot at 6 minutes 42 seconds after contract start time.',
        'shortcode'       => 'CALL_FRXAUDCAD_196.72_1127288260_1127288662_S0P_0',
        'underlying'      => 'frxAUDCAD',
        is_valid_to_sell  => 0,
        validation_error  => 'This contract has been sold.'
    };
    foreach my $key (keys %$expected_result) {
        cmp_ok $res->{$key}, 'eq', $expected_result->{$key}, "$key are matching ";
    }

};

subtest 'get_bid_affected_by_corporate_action' => sub {
    my $opening    = create_underlying('USAAPL')->calendar->opening_on($now);
    my $closing    = create_underlying('USAAPL')->calendar->closing_on($now);
    my $underlying = create_underlying('USAAPL');
    my $starting   = $opening->plus_time_interval('50m');
    my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'USAAPL',
        epoch      => $starting->epoch,
        quote      => 100
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'USAAPL',
        epoch      => $starting->epoch + 30,
        quote      => 111
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'USAAPL',
        epoch      => $starting->epoch + 90,
        quote      => 80
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'USAAPL',
            recorded_date => $opening->plus_time_interval('1d'),
        });

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'USAAPL',
            spot_reference => 100,
            recorded_date  => $opening->plus_time_interval('1d'),
        });

    my $action = {
        11223360 => {
            description    => 'STOCK split ',
            flag           => 'N',
            modifier       => 'divide',
            action_code    => '3000',
            value          => 2,
            effective_date => $opening->plus_time_interval('1d')->date_ddmmmyy,
            type           => 'STOCK_SPLT',
        }};

    Quant::Framework::CorporateAction::create($storage_accessor, 'USAAPL', $opening)->update($action, $opening)->save;

    my $contract = _create_contract(
        client        => $client,
        bet_type      => 'PUT',
        underlying    => 'USAAPL',
        spread        => 0,
        current_tick  => $entry_tick,
        date_start    => $starting,
        date_expiry   => $closing->plus_time_interval('3d'),
        purchase_date => $starting,
        date_pricing  => $starting->plus_time_interval('1550m'),
    );

    my $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    # get_bid calls are supposed to throw a warning during weekend
    # we will capture this warning instead of letting it fail the
    # has_no_warning test which will be called by done_testing().
    my $result;
    warning { $result = $c->call_ok('get_bid', $params) };

    my $wd           = (gmtime time)[6];
    my $skip_weekend = 1
        if ($result->result->{error}
        and $result->result->{error}->{code} eq 'GetProposalFailure'
        and ($wd == 0 or $wd == 6));

    SKIP: {
        my $expected_result = {
            'barrier'               => '55.50',
            'contract_id'           => '20',
            'date_settlement'       => '1127592000',
            'original_barrier'      => '111.00',
            'validation_error'      => 'This contract is affected by corporate action.',
            'currency'              => 'USD',
            'underlying'            => 'USAAPL',
            'entry_tick'            => '111.00',
            'date_start'            => '1127312400',
            'current_spot'          => '80.00',
            'is_intraday'           => '0',
            'contract_type'         => 'PUT',
            'is_expired'            => '0',
            'is_valid_to_sell'      => '0',
            'shortcode'             => 'PUT_USAAPL_1000_1127312400_1127592000_S0P_0',
            'is_forward_starting'   => '0',
            'bid_price'             => '0.00',
            'longcode'              => 'Win payout if Apple is strictly lower than entry spot at close on 2005-09-24.',
            'date_expiry'           => '1127592000',
            'is_path_dependent'     => '0',
            'display_name'          => 'Apple',
            'entry_tick_time'       => '1127312430',
            'entry_spot'            => '111.00',
            'has_corporate_actions' => '1',
            'current_spot_time'     => '1127312490',
            'payout'                => '1000'
        };

        skip 'This test fails on weekends', 2 + keys %$expected_result
            if $skip_weekend;

        $result = $result->has_no_system_error->has_no_error->result;

        foreach my $key (keys %$expected_result) {
            cmp_ok $result->{$key}, 'eq', $expected_result->{$key}, "$key are matching ";
        }
    }
};

subtest 'app_markup_percentage' => sub {
    my $params = {
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "duration"      => "60",
        "duration_unit" => "s",
        "symbol"        => "R_50",
    };
    my $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params));
    my $val    = $result->{ask_price};

    # check for payout proposal - ask_price should increase
    $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params), 1);
    is $result->{ask_price} - $val, 1 / 100 * 100, "as app markup is added so client has to 1% of payout";

    # check app_markup for stake proposal
    $params = {
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "stake",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "duration"      => "60",
        "duration_unit" => "s",
        "symbol"        => "R_50",
    };
    $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params));
    $val    = $result->{payout};

    $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params), 2);
    cmp_ok $val - $result->{payout}, ">", 2 / 100 * $val, "as app markup is added so client will get less payout as compared when there is no markup";

    my $contract = _create_contract(
        client                => $client,
        spread                => 0,
        app_markup_percentage => 1
    );
    $params = {
        short_code            => $contract->shortcode,
        contract_id           => $contract->id,
        currency              => $client->currency,
        is_sold               => 0,
        sell_time             => undef,
        app_markup_percentage => 1
    };
    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    is $contract->payout, $result->{payout}, "contract and get bid payout should be same when app_markup is included";

    $contract = _create_contract(
        client => $client,
        spread => 0
    );

    cmp_ok $contract->payout, ">", $result->{payout}, "payout in case of stake contracts would be higher as compared to app_markup stake contracts";

    $contract = _create_contract(
        client                => $client,
        spread                => 0,
        app_markup_percentage => 1
    );
    $params = {
        short_code            => $contract->shortcode,
        contract_id           => $contract->id,
        currency              => $client->currency,
        is_sold               => 0,
        sell_time             => undef,
        app_markup_percentage => 1
    };
    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    is $contract->payout, $result->{payout}, "contract and get bid payout should be same when app_markup is included";

    $contract = _create_contract(
        client => $client,
        spread => 0
    );
    cmp_ok $contract->payout, ">", $result->{payout}, "payout in case of stake contracts would be higher as compared to app_markup stake contracts";

    $contract = _create_contract(
        client => $client,
        spread => 1
    );
    $contract = _create_contract(
        client                => $client,
        spread                => 0,
        app_markup_percentage => 1
    );
    $params = {
        short_code            => $contract->shortcode,
        contract_id           => $contract->id,
        currency              => $client->currency,
        is_sold               => 0,
        sell_time             => undef,
        app_markup_percentage => 1
    };
    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    is $contract->payout, $result->{payout}, "contract and get bid payout should be same when app_markup is included";

    $contract = _create_contract(
        client => $client,
        spread => 0
    );
    cmp_ok $contract->payout, ">", $result->{payout}, "payout in case of stake contracts would be higher as compared to app_markup stake contracts";

    $contract = _create_contract(
        client => $client,
        spread => 1
    );
    $contract = _create_contract(
        client                => $client,
        spread                => 0,
        app_markup_percentage => 1
    );
    $params = {
        short_code            => $contract->shortcode,
        contract_id           => $contract->id,
        currency              => $client->currency,
        is_sold               => 0,
        sell_time             => undef,
        app_markup_percentage => 1
    };
    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    is $contract->payout, $result->{payout}, "contract and get bid payout should be same when app_markup is included";

    $contract = _create_contract(
        client => $client,
        spread => 0
    );
    cmp_ok $contract->payout, ">", $result->{payout}, "payout in case of stake contracts would be higher as compared to app_markup stake contracts";
};

done_testing();

sub create_ticks {
    my @ticks = @_;

    for my $tick (@ticks) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            quote      => $tick->[0],
            epoch      => $tick->[1],
            underlying => $tick->[2],
        });

    }
    return;
}

sub _create_contract {
    my %args = @_;

    my $client = $args{client};

    #postpone 10 minutes to avoid conflicts
    $now = $now->plus_time_interval('10m');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 99,
        underlying => 'R_50',
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 52,
        underlying => 'R_50',
    });

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
    });

    my $symbol        = $args{underlying} ? $args{underlying} : 'R_50';
    my $date_start    = $now->epoch - 100;
    my $date_expiry   = $now->epoch - 50;
    my $underlying    = create_underlying($symbol);
    my $purchase_date = $now->epoch - 101;
    my $contract_data = {
        underlying            => $underlying,
        bet_type              => $args{bet_type} // 'FLASHU',
        currency              => 'USD',
        current_tick          => $args{current_tick} // $tick,
        stake                 => 100,
        date_start            => $args{date_start} // $date_start,
        date_expiry           => $args{date_expiry} // $date_expiry,
        barrier               => $args{barrier} // 'S0P',
        app_markup_percentage => $args{app_markup_percentage} // 0,

        # this is not what we want to test here.
        # setting it to false.
        uses_empirical_volatility => 0,
    };
    if ($args{date_pricing}) {
        $contract_data->{date_pricing} = $args{date_pricing};
    }

    if ($args{spread}) {
        delete $contract_data->{date_expiry};
        delete $contract_data->{barrier};
        $contract_data->{bet_type}         = 'SPREADU';
        $contract_data->{amount_per_point} = 1;
        $contract_data->{stop_type}        = 'point';
        $contract_data->{stop_profit}      = 10;
        $contract_data->{stop_loss}        = 10;
    }
    my $contract = produce_contract($contract_data);

    my $txn = BOM::Product::Transaction->new({
            client        => $client,
            contract      => $contract,
            price         => 100,
            payout        => $contract->payout,
            amount_type   => 'stake',
            purchase_date => $args{purchase_date}
            ? $args{purchase_date}
            : $purchase_date,
        });

    my $error = $txn->buy(skip_validation => 1);
    ok(!$error, 'should no error to buy the contract');

    return $contract;
}
