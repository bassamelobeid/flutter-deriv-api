use strict;
use warnings;
use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::RPC::v3::Contract;
use BOM::Platform::Context qw (request);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::System::RedisReplicated;
use BOM::Product::ContractFactory qw( produce_contract );
use Data::Dumper;
use Quant::Framework::Utils::Test;
use Quant::Framework::CorporateAction;
use Quant::Framework::StorageAccessor;
use BOM::Database::Model::OAuth;

initialize_realtime_ticks_db();
my $now   = Date::Utility->new('2005-09-21 06:46:00');
my $email = 'test@binary.com';

my $storage_accessor = Quant::Framework::StorageAccessor->new(
    chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
    chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
$client->deposit_virtual_funds;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

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

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
request(BOM::Platform::Context::Request->new(params => {}));
subtest 'validate_symbol' => sub {
    is(BOM::RPC::v3::Contract::validate_symbol('R_50'), undef, "return undef if symbol is valid");
    is_deeply(
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
    is(BOM::RPC::v3::Contract::validate_license('R_50'), undef, "return undef if symbol is is realtime ");

    is_deeply(
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

subtest 'validate_underlying' => sub {
    is_deeply(
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

    is_deeply(
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

    is_deeply(BOM::RPC::v3::Contract::validate_underlying('R_50'), {status => 1}, 'status 1 if everything ok');

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
    is_deeply(BOM::RPC::v3::Contract::prepare_ask($params), $expected, 'prepare_ask result ok');
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
    is_deeply(BOM::RPC::v3::Contract::prepare_ask($params), $expected, 'result is ok after added date_expiry and barrier and barrier2');

    delete $params->{barrier};
    $expected->{barrier} = 'S0P';
    delete $expected->{high_barrier};
    delete $expected->{low_barrier};
    is_deeply(BOM::RPC::v3::Contract::prepare_ask($params),
        $expected, 'will set barrier default value and delete barrier2 if contract type is not like SPREAD and ASIAN');

    delete $expected->{barrier};
    $expected->{barrier2} = 'S1P';
    for my $t (qw(SPREAD ASIAN)) {
        $params->{contract_type} = $t;
        $expected->{bet_type}    = $t;
        is_deeply(BOM::RPC::v3::Contract::prepare_ask($params), $expected, 'will not set barrier if contract type is like SPREAD and ASIAN ');

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
        from_pricer_daemon => 1,
    };
    my $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params));
    ok(delete $result->{spot_time},  'result have spot time');
    ok(delete $result->{date_start}, 'result have date_start');
    my $expected = {
        'display_value'    => '51.49',
        'ask_price'        => '51.49',
        'longcode'         => 'Win payout if Volatility 50 Index is strictly higher than entry spot at 1 minute after contract start time.',
        'spot'             => '963.3054',
        'payout'           => '100',
        'theo_probability' => 0.499862404631018,
    };
    is_deeply($result, $expected, 'the left values are all right');

    $params->{symbol} = "invalid symbol";
    is_deeply(
        BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params)),
        {
            error => {
                message_to_client => 'Cannot create contract',
                code              => "ContractCreationFailure",
            }});

    is_deeply(
        BOM::RPC::v3::Contract::_get_ask({}),
        {
            error => {
                message_to_client => 'Cannot create contract',
                code              => "ContractCreationFailure",
            }});

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
            from_pricer_daemon => 1,
        }};

    my $result = $c->call_ok('send_ask', $params)->has_no_error->result;
    my $expected_keys = [sort { $a cmp $b } (qw(longcode spot display_value ask_price spot_time date_start rpc_time payout theo_probability))];
    is_deeply([sort keys %$result], $expected_keys, 'result keys is correct');
    is(
        $result->{longcode},
        'Win payout if Volatility 50 Index is strictly higher than entry spot at 1 minute after contract start time.',
        'long code  is correct'
    );
    {
        local $SIG{'__WARN__'} = sub {
            my $msg = shift;
            if ($msg !~ /Use of uninitialized value in pattern match/) {
                print STDERR $msg;
            }
        };
        $c->call_ok('send_ask', {args => {}})->has_error->error_code_is('ContractCreationFailure')->error_message_is('Cannot create contract');

        my $mock_contract = Test::MockModule->new('BOM::RPC::v3::Contract');
        $mock_contract->mock('_get_ask', sub { die });
        $c->call_ok('send_ask', {args => {}})->has_error->error_code_is('pricing error')->error_message_is('Unable to price the contract.');
    }
};

subtest 'get_bid' => sub {
    # just one tick for missing market data
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 899,
        underlying => 'R_50',
    });

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
    });

    my $contract = create_contract(
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

    $contract = create_contract(
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
        qw(ask_price
            bid_price
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
            ));
    is_deeply([sort keys %{$result}], [sort @expected_keys]);

    $contract = create_contract(
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

    @expected_keys = (
        qw(ask_price
            bid_price
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

    $c->call_ok($method, $params)
        ->has_error->error_message_is('Sorry, an error occurred while processing your request.', 'will report error if no short_code and currency');

    my $contract = create_contract(
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

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 899,
        underlying => 'frxAUDCAD',
        quote      => 0.9936
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 501,
        underlying => 'frxAUDCAD',
        quote      => 0.9938
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 499,
        underlying => 'frxAUDCAD',
        quote      => 0.9939
    });

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'frxAUDCAD',
        quote      => 0.9935
    });

    $contract = create_contract(
        client        => $client,
        spread        => 0,
        current_tick  => $tick,
        underlying    => 'frxAUDCAD',
        date_start    => $now->epoch - 900,
        date_expiry   => $now->epoch - 500,
        purchase_date => $now->epoch - 901,
        date_pricing  => $now->epoch,
    );
    $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => 'USD',
        is_sold     => 1,
    };
    my $res = $c->call_ok('get_bid', $params)->result;
    my $expected_result = {
        'ask_price'       => '208.81',
        'barrier'         => '0.99360',
        'bid_price'       => '208.81',
        'contract_id'     => 10,
        'currency'        => 'USD',
        'date_expiry'     => 1127287060,
        'date_settlement' => 1127287060,
        'date_start'      => 1127286660,
        'entry_spot'      => '0.99360',
        'entry_tick'      => '0.99360',
        'entry_tick_time' => 1127286661,
        'exit_tick'       => '0.99380',
        'exit_tick_time'  => 1127287059,
        'longcode'        => 'Win payout if AUD/CAD is strictly higher than entry spot at 6 minutes 40 seconds after contract start time.',
        'shortcode'       => 'CALL_FRXAUDCAD_208.81_1127286660_1127287060_S0P_0',
        'underlying'      => 'frxAUDCAD',
    };

    foreach my $key (keys %$expected_result) {
        cmp_ok $res->{$key}, 'eq', $expected_result->{$key}, "$key are matching ";
    }

};

subtest 'get_bid_affected_by_corporate_action' => sub {
    my $opening    = BOM::Market::Underlying->new('USAAPL')->calendar->opening_on($now);
    my $closing    = BOM::Market::Underlying->new('USAAPL')->calendar->closing_on($now);
    my $underlying = BOM::Market::Underlying->new('USAAPL');
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

    Quant::Framework::CorporateAction->create(
        storage_accessor => $storage_accessor,
        symbol           => 'USAAPL',
        for_date         => $opening,
    )->update($action, $opening)->save;

    my $contract = create_contract(
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

    my $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;

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
        'shortcode'             => 'PUT_USAAPL_1333.33_1127312400_1127592000_S0P_0',
        'is_forward_starting'   => '0',
        'bid_price'             => '0.00',
        'longcode'              => 'Win payout if Apple is strictly lower than entry spot at close on 2005-09-24.',
        'date_expiry'           => '1127592000',
        'is_path_dependent'     => '0',
        'display_name'          => 'Apple',
        'ask_price'             => '133.33',
        'entry_tick_time'       => '1127312430',
        'entry_spot'            => '111.00',
        'has_corporate_actions' => '1',
        'current_spot_time'     => '1127312490',
        'payout'                => '1333.33'
    };

    foreach my $key (keys %$expected_result) {
        cmp_ok $result->{$key}, 'eq', $expected_result->{$key}, "$key are matching ";
    }

};

subtest 'app_markup_percentage' => sub {
    my $params = {
        "proposal"         => 1,
        "amount"           => "100",
        "basis"            => "payout",
        "contract_type"    => "CALL",
        "currency"         => "USD",
        "duration"         => "60",
        "duration_unit"    => "s",
        "symbol"           => "R_50",
        from_pricer_daemon => 1,
    };
    my $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params));
    my $val    = $result->{ask_price};
    # check for payout proposal - ask_price should increase
    $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params), 1);
    is $result->{ask_price} - $val, 1 / 100 * 100, "as app markup is added so client has to 1% of payout";

    # check app_markup for stake proposal
    $params = {
        "proposal"         => 1,
        "amount"           => "100",
        "basis"            => "stake",
        "contract_type"    => "CALL",
        "currency"         => "USD",
        "duration"         => "60",
        "duration_unit"    => "s",
        "symbol"           => "R_50",
        from_pricer_daemon => 1,
    };
    $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params));
    $val    = $result->{payout};

    $result = BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params), 2);
    cmp_ok $val - $result->{payout}, ">", 2 / 100 * $val, "as app markup is added so client will get less payout as compared when there is no markup";

    my $contract = create_contract(
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

    $contract = create_contract(
        client => $client,
        spread => 0
    );
    cmp_ok $contract->payout, ">", $result->{payout}, "payout in case of stake contracts would be higher as compared to app_markup stake contracts";

    $contract = create_contract(
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

    $contract = create_contract(
        client => $client,
        spread => 0
    );
    cmp_ok $contract->payout, ">", $result->{payout}, "payout in case of stake contracts would be higher as compared to app_markup stake contracts";

    $contract = create_contract(
        client => $client,
        spread => 1
    );
    $contract = create_contract(
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

    $contract = create_contract(
        client => $client,
        spread => 0
    );
    cmp_ok $contract->payout, ">", $result->{payout}, "payout in case of stake contracts would be higher as compared to app_markup stake contracts";

    $contract = create_contract(
        client => $client,
        spread => 1
    );
    $contract = create_contract(
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

    $contract = create_contract(
        client => $client,
        spread => 0
    );
    cmp_ok $contract->payout, ">", $result->{payout}, "payout in case of stake contracts would be higher as compared to app_markup stake contracts";
};

done_testing();

sub create_contract {
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
    my $underlying    = BOM::Market::Underlying->new($symbol);
    my $purchase_date = $now->epoch - 101;
    my $contract_data = {
        underlying            => $underlying,
        bet_type              => $args{bet_type} // 'FLASHU',
        currency              => 'USD',
        current_tick          => $args{current_tick} // $tick,
        stake                 => 100,
        date_start            => $args{date_start} // $date_start,
        date_expiry           => $args{date_expiry} // $date_expiry,
        barrier               => 'S0P',
        app_markup_percentage => $args{app_markup_percentage} // 0
    };
    if ($args{date_pricing}) { $contract_data->{date_pricing} = $args{date_pricing}; }

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
        purchase_date => $args{purchase_date} ? $args{purchase_date} : $purchase_date,
    });

    my $error = $txn->buy(skip_validation => 1);
    ok(!$error, 'should no error to buy the contract');

    return $contract;
}
