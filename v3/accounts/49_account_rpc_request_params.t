use strict;
use warnings;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use Date::Utility;
use Test::MockModule;
use Test::More;

$ENV{CLIENTIP_PLUGGABLE_ALLOW_LOOPBACK} = 1;

use await;
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;

my $t = build_wsapi_test({language => 'EN'});

# UK Client testing (Start)
my $email = 'uk_client@binary.com';
my $user  = BOM::Platform::User->create(
    email    => $email,
    password => '1234'
);

# Create client (UK - VRTC)
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    residence   => 'gb',
    email       => $email
});

$user->add_loginid({loginid => $client->loginid});
$user->save;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
my $authorize = $t->await::authorize({authorize => $token});

# Test 1
is_deeply $authorize->{authorize}->{upgradeable_accounts}, ['iom'], 'UK client can upgrade to IOM.';

# Create client (UK - MX)
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
    email       => $email
});

$user->add_loginid({loginid => $client->loginid});
$user->save;

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
$authorize = $t->await::authorize({authorize => $token});

# Test 2
is_deeply $authorize->{authorize}->{upgradeable_accounts}, ['maltainvest'], 'UK client can upgrade to maltainvest.';

# Create client (UK - MF)
$client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    residence   => 'gb',
    email       => $email
});

$user->add_loginid({loginid => $client->loginid});
$user->save;

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
$authorize = $t->await::authorize({authorize => $token});

# Test 3
is_deeply $authorize->{authorize}->{upgradeable_accounts}, [], 'UK client has upgraded all accounts.';

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
$user = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$authorize = $t->await::authorize({authorize => $token});
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

$res = $t->await::landing_company({landing_company => 'de'});
is($res->{msg_type}, 'landing_company');
ok(ref $res->{landing_company});

$res = $t->await::landing_company_details({landing_company_details => 'costarica'});
is($res->{msg_type}, 'landing_company_details');
ok(ref $res->{landing_company_details});

$res = $t->await::statement({
    statement => 1,
    limit     => 54
});
ok(ref $res->{statement});
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

$res = $t->await::balance({
    balance   => 1,
    subscribe => 1,
});
ok(ref $res->{balance});
ok($res->{balance}->{id});
is $call_params->{token}, $token;

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

$res = $t->await::cashier_password({cashier_password => 1});
is($res->{cashier_password}, 1);
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
    phone            => "1234567890"
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
$t->await::landing_company_details({landing_company_details => 'costarica'});
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
        account_opening_reason   => "Speculative",
        %{BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash()}});
$t->await::login_history({login_history => 1});
$t->await::get_account_status({get_account_status => 1});
$t->await::change_password({
    change_password => 1,
    old_password    => '123456',
    new_password    => '654321'
});
$t->await::cashier_password({cashier_password => 1});
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
    phone            => "1234567890"
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
