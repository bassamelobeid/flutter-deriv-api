use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use Date::Utility;
use Test::MockModule;
use Test::MockObject;
use Test::More;

$ENV{CLIENTIP_PLUGGABLE_ALLOW_LOOPBACK} = 1;

use await;
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;
use Binary::WebSocketAPI::v3::Subscription::Transaction;
my $t = build_wsapi_test({language => 'EN'});

# UK Client testing (Start)
my $email = 'uk_client@binary.com';
my $user  = BOM::User->create(
    email    => $email,
    password => '1234'
);

# Create client (UK - VRTC)
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    residence   => 'gb',
    email       => $email
});

$user->add_client($client);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
my $authorize = $t->await::authorize({authorize => $token});

# Test 1 (Client should be able to upgrade to IOM)
is_deeply $authorize->{authorize}->{upgradeable_landing_companies}, ['iom'], 'UK client can upgrade to IOM.';

# Create client (UK - MX)
$client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
    email       => $email
});

$user->add_client($client);

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
$authorize = $t->await::authorize({authorize => $token});

# Test 2 (Client should be able to upgrade to maltainvest)
is_deeply $authorize->{authorize}->{upgradeable_landing_companies}, ['maltainvest'], 'UK client can upgrade to maltainvest.';

# Create client (UK - MF)
$client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    residence   => 'gb',
    email       => $email
});

$user->add_client($client);

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
$authorize = $t->await::authorize({authorize => $token});

# Test 3 (Client cannot upgrade anymore)
is_deeply $authorize->{authorize}->{upgradeable_landing_companies}, [], 'UK client has upgraded all accounts.';

# UK Client testing (Done)

# prepare client (normal cr account)
$email  = 'test-binary@binary.com';
$client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

$client->email($email);
$client->save;
$client->set_default_account('USD');

my $loginid = $client->loginid;
$user = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($client);

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $loginid;

my ($rpc_caller, $call_params, $res, $rpc_response);
$rpc_response = {ok => 1};

my $fake_res = Test::MockObject->new();
$fake_res->mock('result',   sub { $rpc_response });
$fake_res->mock('is_error', sub { '' });

my $module = Test::MockModule->new('MojoX::JSON::RPC::Client');
$module->mock('call', sub { shift; $call_params = $_[1]->{params}; return $_[2]->($fake_res) });

my $sync_moduel = Test::MockModule->new('Job::Async::Client::Redis');
$sync_moduel->mock(
    'submit',
    sub {
        my ($self, %args) = @_;
        $call_params = decode_json_utf8($args{params});
        return Future->done(
            encode_json_utf8({
                    success => 1,
                    result  => $rpc_response
                }));
    });

$res = $t->await::landing_company({landing_company => 'de'});
is($res->{msg_type}, 'landing_company');
ok(ref $res->{landing_company});

$res = $t->await::landing_company_details({landing_company_details => 'svg'});
is($res->{msg_type}, 'landing_company_details');
ok(ref $res->{landing_company_details});

$res = $t->await::statement({
    statement => 1,
    limit     => 54
});
ok(ref $res->{statement});
is $call_params->{token}, $token;

$res = $t->await::request_report({
    "request_report" => 1,
    "report_type"    => "statement",
    "date_from"      => 1334036304,
    "date_to"        => 1535036304,
});
ok(ref $res->{request_report});

$res = $t->await::account_statistics({
    "account_statistics" => 1,
});
ok(ref $res->{account_statistics});

is $call_params->{token}, $token;

$res = $t->await::profit_table({
    profit_table => 1,
    limit        => 1,
});
ok(ref $res->{profit_table});
is $call_params->{token}, $token;

$res = $t->await::get_settings({get_settings => 1});
ok(ref $res->{get_settings});
is $call_params->{token},    $token;
is $call_params->{language}, 'EN';

$res = $t->await::get_self_exclusion({get_self_exclusion => 1});
ok(ref $res->{get_self_exclusion});
is $call_params->{token}, $token;

my $old_rpc_response = $rpc_response;
$rpc_response = {
    "balance"    => 1018.86,
    "currency"   => "USD",
    "loginid"    => "CR90000000",
    "account_id" => $client->default_account->id
};
$res = $t->await::balance({
    balance => 1,
    #subscribe => 1,
});
ok(ref $res->{balance});
#ok($res->{balance}->{id});
is $call_params->{token}, $token;

$rpc_response = {
    'all' => [{
            'account_id'                      => $client->default_account->id,
            'balance'                         => '1000.00',
            'currency'                        => 'EUR',
            'currency_rate_in_total_currency' => '1.5',
            'loginid'                         => $client->loginid,
            'total'                           => {
                'mt5' => {
                    'amount'   => '0.00',
                    'currency' => 'USD'
                },
                'real' => {
                    'amount'   => '2500.00',
                    'currency' => 'USD'
                }}
        },
        {
            'account_id'                      => '12345678',
            'balance'                         => '1000.00',
            'currency'                        => 'USD',
            'currency_rate_in_total_currency' => 1,
            'loginid'                         => 'CR12345678',
            'total'                           => {
                'mt5' => {
                    'amount'   => '0.00',
                    'currency' => 'USD'
                },
                'real' => {
                    'amount'   => '2500.00',
                    'currency' => 'USD'
                }}}]};

$res = $t->await::balance({
    balance   => 1,
    account   => 'all',
    subscribe => 1,
});

ok($res->{balance}->{id});
my $expected_res = {
    'balance' => {
        'balance'  => '1000',
        'currency' => 'EUR',
        'loginid'  => 'CR10000',
        'total'    => {
            'mt5' => {
                'amount'   => '0',
                'currency' => 'USD'
            },
            'real' => {
                'amount'   => '2500',
                'currency' => 'USD'
            }}
    },
    'echo_req' => {
        'account'   => 'all',
        'balance'   => 1,
        'req_id'    => 1000013,
        'subscribe' => 1
    },
    'msg_type'    => 'balance',
    'passthrough' => undef,
    'req_id'      => 1000013
};
$expected_res->{balance}{id}      = $res->{balance}{id};
$expected_res->{subscription}{id} = $res->{balance}{id};
is_deeply(
    $res,
    $expected_res,
    "result is ok"

);

$res = $t->await::balance();
ok($res->{balance}->{id});
$expected_res = {
    'balance' => {
        'balance'  => '1000',
        'currency' => 'USD',
        'loginid'  => 'CR12345678',
        'total'    => {
            'mt5' => {
                'amount'   => '0',
                'currency' => 'USD'
            },
            'real' => {
                'amount'   => '2500',
                'currency' => 'USD'
            }}
    },
    'echo_req' => {
        'account'   => 'all',
        'balance'   => 1,
        'req_id'    => 1000013,
        'subscribe' => 1,
    },
    'msg_type'    => 'balance',
    'passthrough' => undef,
    'req_id'      => 1000013
};

$expected_res->{balance}{id}      = $res->{balance}{id};
$expected_res->{subscription}{id} = $res->{balance}{id};

is_deeply($res, $expected_res, "the second result ok");

use BOM::Config::RedisReplicated;
use JSON::MaybeUTF8 qw(:v1);
my $msg = {
    account_id    => $client->default_account->id,
    amount        => 200,
    balance_after => 1200
};
$msg = encode_json_utf8($msg);
# I tried to publish message by redis directly ,but the system cannot receive the message. I don't know why
Binary::WebSocketAPI::v3::Subscription::Transaction->subscription_manager()
    ->on_message(undef, $msg, 'TXNUPDATE::transaction_' . $client->default_account->id);
$res = $t->await::balance();
my $expected_res2 = {
    'balance' => {
        'balance'  => '1200',
        'currency' => 'EUR',
        'id'       => $expected_res->{balance}{id},
        'loginid'  => $client->loginid,
        'total'    => {
            'real' => {
                'amount'   => '2800',
                'currency' => 'USD'
            }}
    },
    'echo_req' => {
        'account'   => 'all',
        'balance'   => 1,
        'req_id'    => 1000013,
        'subscribe' => 1
    },
    'msg_type'     => 'balance',
    'req_id'       => 1000013,
    'subscription' => {
        'id' => $expected_res->{balance}{id},
    }};
is_deeply($res, $expected_res2, "update balance ok");
#diag(explain($res));

$res = $t->await::forget_all({forget_all => 'balance'});
is($res->{forget_all}[0], $expected_res->{subscription}{id}, 'forget subscription ok');

$rpc_response = $old_rpc_response;

$res = $t->await::api_token({api_token => 1});
ok(ref $res->{api_token});
is $call_params->{token}, $token;
ok $call_params->{account_id};

$res = $t->await::get_financial_assessment({get_financial_assessment => 1});
ok(ref $res->{get_financial_assessment});
is $call_params->{token}, $token;

$res = $t->await::reality_check({reality_check => 1});
ok(ref $res->{reality_check});
is $call_params->{token}, $token;

$res = $t->await::set_financial_assessment({%{BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash()}, set_financial_assessment => 1});
ok(ref $res->{set_financial_assessment});

is $call_params->{token}, $token;

$rpc_response = [qw/ test /];
$res = $t->await::payout_currencies({payout_currencies => 1});
ok(ref $res->{payout_currencies});
is $call_params->{token}, $token;

$rpc_response = {
    records => [{
            time        => 1,
            action      => 's',
            environment => 's',
            status      => 1
        }]};
$res = $t->await::login_history({login_history => 1});
ok(ref $res->{login_history});
is $call_params->{token}, $token;

%$rpc_response = (
    status                        => [],
    risk_classification           => 1,
    prompt_client_to_authenticate => '1',
);
$res = $t->await::get_account_status({get_account_status => 1});
ok(ref $res->{get_account_status});
is $call_params->{token}, $token;

%$rpc_response = (status => 1);
$res = $t->await::change_password({
    change_password => 1,
    old_password    => '123456',
    new_password    => '654321'
});
is($res->{change_password}, 1);
is $call_params->{token}, $token;
ok $call_params->{client_ip};
ok $call_params->{token_type};

is $call_params->{token}, $token;
ok $call_params->{client_ip};

$res = $t->await::reset_password({
    reset_password    => 1,
    verification_code => '123456789012345',
    new_password      => '123456'
});
is($res->{reset_password}, 1);
$res = $t->await::set_settings({
    set_settings     => 1,
    address_line_1   => "Test Address Line 1",
    address_line_2   => "Test Address Line 2",
    address_city     => "Test City",
    address_state    => "01",
    address_postcode => "123456",
    phone            => "+15417543010"
});
is($res->{set_settings},     1);
is($call_params->{language}, 'EN');
is($call_params->{token},    $token);
ok($call_params->{server_name});
ok($call_params->{client_ip});
ok($call_params->{user_agent});

$res = $t->await::set_self_exclusion({
    set_self_exclusion => 1,
    max_balance        => 9999,
    max_turnover       => 1000,
    max_open_bets      => 100
});

is($res->{set_self_exclusion}, 1);
is($call_params->{token},      $token);

$res = $t->await::tnc_approval({tnc_approval => 1});
is($res->{tnc_approval},  1);
is($call_params->{token}, $token);

$res = $t->await::set_account_currency({set_account_currency => 'EUR'});
is($res->{set_account_currency}, 1);
is($call_params->{token},        $token);
is($call_params->{currency},     'EUR');

# Test error messages
$rpc_response = {error => {code => 'error'}};
$t->await::payout_currencies({payout_currencies => 1});
$t->await::landing_company({landing_company => 'de'});
$t->await::landing_company_details({landing_company_details => 'svg'});
$t->await::statement({
    statement => 1,
    limit     => 54
});
$t->await::profit_table({
    profit_table => 1,
    limit        => 1
});
$t->await::get_settings({get_settings => 1});
$t->await::get_self_exclusion({get_self_exclusion => 1});
$t->await::balance({
    balance   => 1,
    subscribe => 1
});
$t->await::api_token({api_token => 1});
$t->await::get_financial_assessment({get_financial_assessment => 1});
$t->await::reality_check({reality_check => 1});
$t->await::set_financial_assessment({
        set_financial_assessment => 1,
        %{BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash()}});
$t->await::login_history({login_history => 1});
$t->await::get_account_status({get_account_status => 1});
$t->await::change_password({
    change_password => 1,
    old_password    => '123456',
    new_password    => '654321'
});
$t->await::reset_password({
    reset_password    => 1,
    verification_code => '123456789012345',
    new_password      => '123456'
});
$t->await::set_settings({
    set_settings     => 1,
    address_line_1   => "Test Address Line 1",
    address_line_2   => "Test Address Line 2",
    address_city     => "Test City",
    address_state    => "01",
    address_postcode => "123456",
    phone            => "+15417543010"
});
$t->await::set_self_exclusion({
    set_self_exclusion => 1,
    max_balance        => 9999,
    max_turnover       => 1000,
    max_open_bets      => 100
});
$t->await::tnc_approval({tnc_approval => 1});
$t->await::set_account_currency({set_account_currency => 'EUR'});

$t->finish_ok;

done_testing();
