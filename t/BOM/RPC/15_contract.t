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

use Data::Dumper;

initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new
    });

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
#request(BOM::Platform::Context::Request->new(params => {l => 'ZH_CN'}));
#subtest 'validate_symbol' => sub {
#    is(BOM::RPC::v3::Contract::validate_symbol('R_50'), undef, "return undef if symbol is valid");
#    is_deeply(
#        BOM::RPC::v3::Contract::validate_symbol('invalid_symbol'),
#        {
#            'error' => {
#                'message_to_client' => 'invalid_symbol 符号无效',
#                'code'              => 'InvalidSymbol'
#            }
#        },
#        'return error if symbol is invalid'
#    );
#};
#
#subtest 'validate_license' => sub {
#    is(BOM::RPC::v3::Contract::validate_license('R_50'), undef, "return undef if symbol is is realtime ");
#
#    is_deeply(
#        BOM::RPC::v3::Contract::validate_license('JCI'),
#        {
#            error => {
#                message_to_client => '实时报价不可用于JCI',
#                code              => 'NoRealtimeQuotes'
#            }
#        },
#        "return error if symbol is not realtime"
#    );
#
#};
#
#subtest 'validate_underlying' => sub {
#    is_deeply(
#        BOM::RPC::v3::Contract::validate_underlying('invalid_symbol'),
#        {
#            'error' => {
#                'message_to_client' => 'invalid_symbol 符号无效',
#                'code'              => 'InvalidSymbol'
#            }
#        },
#        'return error if symbol is invalid'
#    );
#
#    is_deeply(
#        BOM::RPC::v3::Contract::validate_underlying('JCI'),
#        {
#            error => {
#                message_to_client => '实时报价不可用于JCI',
#                code              => 'NoRealtimeQuotes'
#            }
#        },
#        "return error if symbol is not realtime"
#    );
#
#    is_deeply(BOM::RPC::v3::Contract::validate_underlying('R_50'), {status => 1}, 'status 1 if everything ok');
#
#};
#
#subtest 'prepare_ask' => sub {
#    my $params = {
#        "proposal"      => 1,
#        "subscribe"     => 1,
#        "amount"        => "2",
#        "basis"         => "payout",
#        "contract_type" => "CALL",
#        "currency"      => "USD",
#        "symbol"        => "R_50",
#        "duration"      => "2",
#        "duration_unit" => "m"
#    };
#    my $expected = {
#        'barrier'     => 'S0P',
#        'subscribe'   => 1,
#        'duration'    => '2m',
#        'amount_type' => 'payout',
#        'bet_type'    => 'CALL',
#        'underlying'  => 'R_50',
#        'currency'    => 'USD',
#        'amount'      => '2',
#        'proposal'    => 1,
#        'date_start'  => 0
#    };
#    is_deeply(BOM::RPC::v3::Contract::prepare_ask($params), $expected, 'prepare_ask result ok');
#    $params = {
#        %$params,
#        date_expiry => '2015-01-01',
#        barrier     => 'S0P',
#        barrier2    => 'S1P',
#    };
#    $expected = {
#        %$expected,
#        fixed_expiry  => 1,
#        high_barrier  => 'S0P',
#        low_barrier   => 'S1P',
#        date_expiry   => '2015-01-01',
#        duration_unit => 'm',
#        duration      => '2',
#    };
#    delete $expected->{barrier};
#    delete $expected->{barrier2};
#    is_deeply(BOM::RPC::v3::Contract::prepare_ask($params), $expected, 'result is ok after added date_expiry and barrier and barrier2');
#
#    delete $params->{barrier};
#    $expected->{barrier} = 'S0P';
#    delete $expected->{high_barrier};
#    delete $expected->{low_barrier};
#    is_deeply(BOM::RPC::v3::Contract::prepare_ask($params),
#        $expected, 'will set barrier default value and delete barrier2 if contract type is not like SPREAD and ASIAN');
#
#    delete $expected->{barrier};
#    $expected->{barrier2} = 'S1P';
#    for my $t (qw(SPREAD ASIAN)) {
#        $params->{contract_type} = $t;
#        $expected->{bet_type}    = $t;
#        is_deeply(BOM::RPC::v3::Contract::prepare_ask($params), $expected, 'will not set barrier if contract type is like SPREAD and ASIAN ');
#
#    }
#
#};
#
#subtest 'get_ask' => sub {
#    my $params = {
#        "proposal"      => 1,
#        "amount"        => "100",
#        "basis"         => "payout",
#        "contract_type" => "CALL",
#        "currency"      => "USD",
#        "duration"      => "60",
#        "duration_unit" => "s",
#        "symbol"        => "R_50",
#    };
#    #BOM::System::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;');
#    my $result = BOM::RPC::v3::Contract::get_ask(BOM::RPC::v3::Contract::prepare_ask($params));
#    ok(delete $result->{spot_time},  'result have spot time');
#    ok(delete $result->{date_start}, 'result have date_start');
#    my $expected = {
#        'display_value' => '51.49',
#        'ask_price'     => '51.49',
#        'longcode' => '如果随机 50 指数在合约开始时间之后到1 分钟时严格高于入市现价，将获得USD100.00的赔付额。',
#        'spot'     => '963.3054',
#        'payout'   => '100'
#    };
#    is_deeply($result, $expected, 'the left values are all right');
#
#    $params->{symbol} = "invalid symbol";
#    is_deeply(
#        BOM::RPC::v3::Contract::get_ask(BOM::RPC::v3::Contract::prepare_ask($params)),
#        {
#            error => {
#                message => '不在此段期间提供交易。',
#                code    => "ContractBuyValidationError",
#            }});
#
#    #TODO I should  tesk the error of 'ContractBuyValidationError', But I don't know how to build a scenario to get there.
#
#    is_deeply(
#        BOM::RPC::v3::Contract::get_ask({}),
#        {
#            error => {
#                message => '无法创建合约',
#                code    => "ContractCreationFailure",
#            }});
#
#};

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
    #TODO:  Here it will print 2 warnings:
    # Use of uninitialized value $country in hash element at /home/git/regentmarkets/bom-platform/lib/BOM/Platform/Runtime.pm line 130.
    #Use of uninitialized value $country in hash element at /home/git/regentmarkets/bom-platform/lib/BOM/Platform/Runtime.pm line 122.
    # That's because the request has no country_code. I don't know why the function _build_country_code doesn't run yet.

    my $result = $c->call_ok('send_ask', $params)->has_no_error->result;
    my $expected_keys = [sort (qw(longcode spot display_value ask_price spot_time date_start rpc_time payout))];
    is_deeply([sort keys %$result], $expected_keys, 'result keys is correct');
    is(
        $result->{longcode},
        '如果随机 50 指数在合约开始时间之后到1 分钟时严格高于入市现价，将获得USD100.00的赔付额。',
        'long code  is correct'
    );
    $c->call_ok(
        'send_ask',
        {
            language => 'ZH_CN',
            args     => {}})->has_error->error_code_is('ContractCreationFailure')->error_message_is('无法创建合约');

    my $mock_contract = Test::MockModule->new('BOM::RPC::v3::Contract');
    $mock_contract->mock('get_ask', sub { die });
    $c->call_ok(
        'send_ask',
        {
            language => 'ZH_CN',
            args     => {}})->has_error->error_code_is('pricing error')->error_message_is('无法提供合约售价。');

};

subtest 'get_bid' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $fmb = create_fmb(
        $client,
        buy_bet    => 1,
        underlying => 'R_50',
    )->financial_market_bet_record;
    my $params = {
        language    => 'ZH_CN',
        short_code  => $fmb->{short_code},
        contract_id => $fmb->{id},
        currency    => $client->currency,
        is_sold     => $fmb->{is_sold},
    };
    diag(Dumper($c->call_ok('get_bid', $params)->result));
    ok(1);
};

done_testing();

sub create_fmb {
    my ($client, %params) = @_;

    my $account = $client->set_default_account('USD');
    return BOM::Test::Data::Utility::UnitTestDatabase::create_fmb_with_ticks({
        type               => 'fmb_higher_lower_call_buy',
        short_code_prefix  => 'CALL_R_50_26.49',
        short_code_postfix => 'S0P_0',
        account_id         => $account->id,
        buy_bet            => 0,
        %params,
    });
}
