use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use Test::MockModule;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

my $t = build_wsapi_test({language => 'EN'});

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->save;
$client->set_default_account('USD');

my $loginid = $client->loginid;
my $user    = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $loginid;

my ($rpc_caller, $call_params, $res, $rpc_response);
$rpc_response = {ok => 1};

my $fake_res = Test::MockObject->new();
$fake_res->mock('result',   sub { $rpc_response });
$fake_res->mock('is_error', sub { '' });

my $fake_rpc_client = Test::MockObject->new();
$fake_rpc_client->mock('call', sub { shift; $call_params = $_[1]->{params}; return $_[2]->($fake_res) });

my $module = Test::MockModule->new('MojoX::JSON::RPC::Client');
$module->mock('new', sub { return $fake_rpc_client });

$t = $t->send_ok({json => {landing_company => 'de'}})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'landing_company');
ok(ref $res->{landing_company});

$t = $t->send_ok({json => {landing_company_details => 'costarica'}})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'landing_company_details');
ok(ref $res->{landing_company_details});

$t = $t->send_ok({
        json => {
            statement => 1,
            limit     => 54
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'statement');
ok(ref $res->{statement});
is $call_params->{token}, $token;

$t = $t->send_ok({
        json => {
            profit_table => 1,
            limit        => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'profit_table');
ok(ref $res->{profit_table});
is $call_params->{token}, $token;

$t = $t->send_ok({
        json => {
            get_settings => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'get_settings');
ok(ref $res->{get_settings});
is $call_params->{token},    $token;
is $call_params->{language}, 'EN';

$t = $t->send_ok({
        json => {
            get_self_exclusion => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'get_self_exclusion');
ok(ref $res->{get_self_exclusion});
is $call_params->{token}, $token;

$t = $t->send_ok({
        json => {
            balance   => 1,
            subscribe => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'balance');
ok(ref $res->{balance});
ok($res->{balance}->{id});
is $call_params->{token}, $token;

$t = $t->send_ok({
        json => {
            api_token => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'api_token');
ok(ref $res->{api_token});
is $call_params->{token}, $token;
ok $call_params->{account_id};

$t = $t->send_ok({
        json => {
            get_financial_assessment => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'get_financial_assessment');
ok(ref $res->{get_financial_assessment});
is $call_params->{token}, $token;

$t = $t->send_ok({
        json => {
            reality_check => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'reality_check');
ok(ref $res->{reality_check});
is $call_params->{token}, $token;

$t = $t->send_ok({
        json => {
            "set_financial_assessment"             => 1,
            "forex_trading_experience"             => "Over 3 years",
            "account_opening_reason"               => "Speculative",
            "account_turnover"                     => 'Less than $25,000',
            "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
            "indices_trading_experience"           => "1-2 years",
            "indices_trading_frequency"            => "40 transactions or more in the past 12 months",
            "commodities_trading_experience"       => "1-2 years",
            "commodities_trading_frequency"        => "0-5 transactions in the past 12 months",
            "stocks_trading_experience"            => "1-2 years",
            "stocks_trading_frequency"             => "0-5 transactions in the past 12 months",
            "other_derivatives_trading_experience" => "Over 3 years",
            "other_derivatives_trading_frequency"  => "0-5 transactions in the past 12 months",
            "other_instruments_trading_experience" => "Over 3 years",
            "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",
            "employment_industry"                  => "Finance",
            "education_level"                      => "Secondary",
            "income_source"                        => "Self-Employed",
            "net_income"                           => '$25,000 - $50,000',
            "estimated_worth"                      => '$100,000 - $250,000',
            "occupation"                           => 'Managers'
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'set_financial_assessment');
ok(ref $res->{set_financial_assessment});
is $call_params->{token}, $token;

$rpc_response = [qw/ test /];
$t            = $t->send_ok({json => {payout_currencies => 1}})->message_ok;
$res          = decode_json($t->message->[1]);
is($res->{msg_type}, 'payout_currencies');
ok(ref $res->{payout_currencies});
is $call_params->{token}, $token;

$rpc_response = {
    records => [{
            time        => 1,
            action      => 's',
            environment => 's',
            status      => 1
        }]};
$t = $t->send_ok({
        json => {
            login_history => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'login_history');
ok(ref $res->{login_history});
is $call_params->{token}, $token;

%$rpc_response = (
    status              => [],
    risk_classification => 1
);
$t = $t->send_ok({
        json => {
            get_account_status => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'get_account_status');
ok(ref $res->{get_account_status});
is $call_params->{token}, $token;

%$rpc_response = (status => 1);
$t = $t->send_ok({
        json => {
            change_password => 1,
            old_password    => '123456',
            new_password    => '654321',
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type},        'change_password');
is($res->{change_password}, 1);
is $call_params->{token}, $token;
ok $call_params->{client_ip};
ok $call_params->{token_type};

$t = $t->send_ok({
        json => {
            cashier_password => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type},         'cashier_password');
is($res->{cashier_password}, 1);
is $call_params->{token}, $token;
ok $call_params->{client_ip};

$t = $t->send_ok({
        json => {
            reset_password    => 1,
            verification_code => '123456789012345',
            new_password      => '123456',
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type},       'reset_password');
is($res->{reset_password}, 1);

$t = $t->send_ok({
        json => {
            "set_settings"     => 1,
            "address_line_1"   => "Test Address Line 1",
            "address_line_2"   => "Test Address Line 2",
            "address_city"     => "Test City",
            "address_state"    => "01",
            "address_postcode" => "123456",
            "phone"            => "1234567890"
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type},         'set_settings');
is($res->{set_settings},     1);
is($call_params->{language}, 'EN');
is($call_params->{token},    $token);
ok($call_params->{server_name});
ok($call_params->{client_ip});
ok($call_params->{user_agent});

$t = $t->send_ok({
        json => {
            set_self_exclusion => 1,
            max_balance        => 9999,
            max_turnover       => 1000,
            max_open_bets      => 100,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type},           'set_self_exclusion');
is($res->{set_self_exclusion}, 1);
is($call_params->{token},      $token);

$t = $t->send_ok({
        json => {
            tnc_approval => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type},      'tnc_approval');
is($res->{tnc_approval},  1);
is($call_params->{token}, $token);

$t = $t->send_ok({
        json => {
            set_account_currency => 'EUR',
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type},             'set_account_currency');
is($res->{set_account_currency}, 1);
is($call_params->{token},        $token);
is($call_params->{currency},     'EUR');

# Test error messages
$rpc_response = {error => {code => 'error'}};
$t = $t->send_ok({json => {payout_currencies => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'payout_currencies');

$t = $t->send_ok({json => {landing_company => 'de'}})->message_ok;
$res = decode_json($t->message->[1]);

$t = $t->send_ok({json => {landing_company_details => 'costarica'}})->message_ok;
$res = decode_json($t->message->[1]);

$t = $t->send_ok({
        json => {
            statement => 1,
            limit     => 54
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'statement');

$t = $t->send_ok({
        json => {
            profit_table => 1,
            limit        => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'profit_table');

$t = $t->send_ok({
        json => {
            get_settings => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'get_settings');

$t = $t->send_ok({
        json => {
            get_self_exclusion => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'get_self_exclusion');

$t = $t->send_ok({
        json => {
            balance   => 1,
            subscribe => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'balance');

$t = $t->send_ok({
        json => {
            api_token => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'api_token');

$t = $t->send_ok({
        json => {
            get_financial_assessment => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'get_financial_assessment');

$t = $t->send_ok({
        json => {
            reality_check => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'reality_check');

$t = $t->send_ok({
        json => {
            "set_financial_assessment"             => 1,
            "account_opening_reason"               => "Speculative",
            "account_turnover"                     => "Less than $25,000",
            "forex_trading_experience"             => "Over 3 years",
            "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
            "indices_trading_experience"           => "1-2 years",
            "indices_trading_frequency"            => "40 transactions or more in the past 12 months",
            "commodities_trading_experience"       => "1-2 years",
            "commodities_trading_frequency"        => "0-5 transactions in the past 12 months",
            "stocks_trading_experience"            => "1-2 years",
            "stocks_trading_frequency"             => "0-5 transactions in the past 12 months",
            "other_derivatives_trading_experience" => "Over 3 years",
            "other_derivatives_trading_frequency"  => "0-5 transactions in the past 12 months",
            "other_instruments_trading_experience" => "Over 3 years",
            "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",
            "employment_industry"                  => "Finance",
            "education_level"                      => "Secondary",
            "income_source"                        => "Self-Employed",
            "net_income"                           => '$25,000 - $100,000',
            "estimated_worth"                      => '$100,000 - $250,000',
            "occupation"                           => 'Managers'
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'set_financial_assessment');

$t = $t->send_ok({
        json => {
            login_history => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'login_history');

$t = $t->send_ok({
        json => {
            get_account_status => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'get_account_status');

$t = $t->send_ok({
        json => {
            change_password => 1,
            old_password    => '123456',
            new_password    => '654321',
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'change_password');

$t = $t->send_ok({
        json => {
            cashier_password => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'cashier_password');

$t = $t->send_ok({
        json => {
            reset_password    => 1,
            verification_code => '123456789012345',
            new_password      => '123456',
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'reset_password');

$t = $t->send_ok({
        json => {
            "set_settings"     => 1,
            "address_line_1"   => "Test Address Line 1",
            "address_line_2"   => "Test Address Line 2",
            "address_city"     => "Test City",
            "address_state"    => "01",
            "address_postcode" => "123456",
            "phone"            => "1234567890"
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'set_settings');

$t = $t->send_ok({
        json => {
            set_self_exclusion => 1,
            max_balance        => 9999,
            max_turnover       => 1000,
            max_open_bets      => 100,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'set_self_exclusion');

$t = $t->send_ok({
        json => {
            tnc_approval => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'tnc_approval');

$t = $t->send_ok({
        json => {
            set_account_currency => 'EUR',
        }})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{msg_type}, 'set_account_currency');

$t->finish_ok;

done_testing();
