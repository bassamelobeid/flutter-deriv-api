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
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::System::RedisReplicated;
use BOM::Product::ContractFactory qw( produce_contract );
use Data::Dumper;

initialize_realtime_ticks_db();
my $now    = Date::Utility->new('2005-09-21 06:46:00');
my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
$client->deposit_virtual_funds;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $client->loginid,
    email   => $email
)->token;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new
    });

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
request(BOM::Platform::Context::Request->new(params => {l => 'ZH_CN'}));
subtest 'validate_symbol' => sub {
    is(BOM::RPC::v3::Contract::validate_symbol('R_50'), undef, "return undef if symbol is valid");
    is_deeply(
        BOM::RPC::v3::Contract::validate_symbol('invalid_symbol'),
        {
            'error' => {
                'message_to_client' => 'invalid_symbol 符号无效',
                'code'              => 'InvalidSymbol'
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
                message_to_client => '实时报价不可用于JCI',
                code              => 'NoRealtimeQuotes'
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
                'message_to_client' => 'invalid_symbol 符号无效',
                'code'              => 'InvalidSymbol'
            }
        },
        'return error if symbol is invalid'
    );

    is_deeply(
        BOM::RPC::v3::Contract::validate_underlying('JCI'),
        {
            error => {
                message_to_client => '实时报价不可用于JCI',
                code              => 'NoRealtimeQuotes'
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
    ok(delete $result->{spot_time},  'result have spot time');
    ok(delete $result->{date_start}, 'result have date_start');
    my $expected = {
        'display_value' => '51.49',
        'ask_price'     => '51.49',
        'longcode' => '如果随机 50 指数在合约开始时间之后到1 分钟时严格高于入市现价，将获得USD100.00的赔付额。',
        'spot'     => '963.3054',
        'payout'   => '100'
    };
    is_deeply($result, $expected, 'the left values are all right');

    $params->{symbol} = "invalid symbol";
    is_deeply(
        BOM::RPC::v3::Contract::_get_ask(BOM::RPC::v3::Contract::prepare_ask($params)),
        {
            error => {
                message => '不在此段期间提供交易。',
                code    => "ContractBuyValidationError",
            }});

    is_deeply(
        BOM::RPC::v3::Contract::_get_ask({}),
        {
            error => {
                message => '无法创建合约',
                code    => "ContractCreationFailure",
            }});

};

subtest 'send_ask' => sub {
    my $params = {
        language  => 'ZH_CN',
        client_ip => '127.0.0.1',
        args      => {
            "proposal"      => 1,
            "amount"        => "100",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "duration"      => "60",
            "duration_unit" => "s",
            "symbol"        => "R_50",
        }};

    my $result = $c->call_ok('send_ask', $params)->has_no_error->result;
    my $expected_keys = [sort (qw(longcode spot display_value ask_price spot_time date_start rpc_time payout))];
    is_deeply([sort keys %$result], $expected_keys, 'result keys is correct');
    is(
        $result->{longcode},
        '如果随机 50 指数在合约开始时间之后到1 分钟时严格高于入市现价，将获得USD100.00的赔付额。',
        'long code  is correct'
    );
    {
        local $SIG{'__WARN__'} = sub {
            my $msg = shift;
            if ($msg !~ /Use of uninitialized value in pattern match/) {
                print STDERR $msg;
            }
        };
        $c->call_ok(
            'send_ask',
            {
                language => 'ZH_CN',
                args     => {}})->has_error->error_code_is('ContractCreationFailure')->error_message_is('无法创建合约');

        my $mock_contract = Test::MockModule->new('BOM::RPC::v3::Contract');
        $mock_contract->mock('_get_ask', sub { die });
        $c->call_ok(
            'send_ask',
            {
                language => 'ZH_CN',
                args     => {}})->has_error->error_code_is('pricing error')->error_message_is('无法提供合约售价。');
    }
};

subtest 'get_bid' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 899,
        underlying => 'R_50',
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 850,
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
        language    => 'ZH_CN',
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };
    my $result =
        $c->call_ok('get_bid', $params)->has_error->error_code_is('GetProposalFailure')
        ->error_message_is(
        '在合约期限内出现市场数据中断。对于真实资金账户，我们将尽力修正并恰当地结算合约，不然合约将取消及退款。对于虚拟资金交易，我们将取消交易，并退款。'
        );
    $params = {language => 'ZH_CN'};

    $c->call_ok('get_bid', $params)->has_error->error_code_is('GetProposalFailure')
        ->error_message_is('对不起，在处理您的请求时出错。');

    $contract = create_contract(
        client => $client,
        spread => 1
    );

    $params = {
        language    => 'ZH_CN',
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;

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
            ));
    is_deeply([sort keys %{$result}], [sort @expected_keys]);

    $contract = create_contract(
        client => $client,
        spread => 0
    );

    $params = {
        language    => 'ZH_CN',
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;

    push @expected_keys, qw(
        barrier
        exit_tick_time
        exit_tick
        entry_tick
        entry_tick_time
        current_spot
        entry_spot
    );
    is_deeply([sort keys %{$result}], [sort @expected_keys], 'keys of result is correct');

};

my $method = 'get_contract_details';
subtest $method => sub {
    my $params = {
        language => 'zh_CN',
        token    => '12345'
    };

    $c->call_ok($method, $params)->has_error->error_message_is('令牌无效。', 'invalid token');
    $client->set_status('disabled', 1, 'test');
    $client->save;
    $params->{token} = $token;
    $c->call_ok($method, $params)->has_error->error_message_is('此账户不可用。', 'invalid token');
    $client->clr_status('disabled');
    $client->save;

    $c->call_ok($method, $params)
        ->has_error->error_message_is('对不起，在处理您的请求时出错。', 'will report error if no short_code and currency');

    my $contract = create_contract(
        client => $client,
        spread => 0
    );
    $params->{short_code} = $contract->shortcode;
    $params->{currency}   = 'USD';
    $c->call_ok($method, $params)->has_no_error->result_is_deeply({
            'symbol' => 'R_50',
            'longcode' =>
                "如果随机 50 指数在合约开始时间之后到50 秒钟时严格高于入市现价，将获得USD194.22的赔付额。",
            'display_name' => 'Random 50 Index',
            'date_expiry'  => $now->epoch - 50,
        },
        'result is ok'
    );

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
    my $date_start    = $now->epoch - 100;
    my $date_expiry   = $now->epoch - 50;
    my $underlying    = BOM::Market::Underlying->new('R_50');
    my $purchase_date = $now->epoch - 101;
    my $contract_data = {
        underlying   => $underlying,
        bet_type     => 'FLASHU',
        currency     => 'USD',
        current_tick => $args{current_tick} ? $args{current_tick} : $tick,
        stake        => 100,
        date_start   => $args{date_start} ? $args{date_start} : $date_start,
        date_expiry  => $args{date_expiry} ? $args{date_expiry} : $date_expiry,
        barrier      => 'S0P',
    };

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
