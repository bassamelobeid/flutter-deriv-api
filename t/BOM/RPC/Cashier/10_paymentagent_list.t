use strict;
use warnings;

use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::SessionCookie;
use utf8;

# init test data

my $email       = 'raunak@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::System::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $test_client->loginid,
    email   => $email
)->token;

my $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client->set_default_account('USD');

# make him a payment agent
$pa_client->payment_agent({
    payment_agent_name    => 'Joe',
    url                   => 'http://www.example.com/',
    email                 => 'joe@example.com',
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'USD',
    currency_code_2       => 'USD',
    target_country        => 'id',
});
$pa_client->save;

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

# start test
my $method = 'paymentagent_list';
my $params = {
    language => 'zh_CN',
    token    => '12345',
    args     => {paymentagent_list => 'id'},
};

my $expected_result = {
    'available_countries' => [['id', '印度尼西亚',], ['', undef]],
    'list' => [{
            'telephone'             => '+12345678',
            'supported_banks'       => undef,
            'name'                  => 'Joe',
            'further_information'   => 'Test Info',
            'deposit_commission'    => '0',
            'withdrawal_commission' => '0',
            'currencies'            => 'USD',
            'email'                 => 'joe@example.com',
            'summary'               => 'Test Summary',
            'url'                   => 'http://www.example.com/',
            'paymentagent_loginid'  => $pa_client->loginid,
        }]};
$c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'If token is invalid, then the paymentagents are from broker "CR"');

$params->{token} = $token;
$c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, "If token is valid, then the paymentagents are from client's broker");

# TODO:
# I want to test a client with broker 'MF', so the result should be empty. But I cannot, because seems all broker data are in one db on QA and travis
done_testing();

