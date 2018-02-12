use strict;
use warnings;

use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Platform::Password;

use utf8;

# init test data

my $email       = 'raunak@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::Platform::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

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
    target_country        => 'id',
});
$pa_client->save;

my $first_pa_loginid = $pa_client->loginid;

$pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client->set_default_account('BTC');

# make him a payment agent
$pa_client->payment_agent({
    payment_agent_name    => 'Hoe',
    url                   => 'http://www.sample.com/',
    email                 => 'hoe@sample.com',
    phone                 => '+12345678',
    information           => 'Test Information',
    summary               => 'Test Summary Another',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'BTC',
    target_country        => 'id',
});
$pa_client->save;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

# start test
my $method = 'paymentagent_list';
my $params = {
    language => 'EN',
    token    => '12345',
    args     => {paymentagent_list => 'id'},
};

my $expected_result = {
    'available_countries' => [['id', 'Indonesia',], ['', undef]],
    'list' => [{
            'telephone'             => '+12345678',
            'supported_banks'       => undef,
            'name'                  => 'Hoe',
            'further_information'   => 'Test Information',
            'deposit_commission'    => '0',
            'withdrawal_commission' => '0',
            'currencies'            => 'BTC',
            'email'                 => 'hoe@sample.com',
            'summary'               => 'Test Summary Another',
            'url'                   => 'http://www.sample.com/',
            'paymentagent_loginid'  => $pa_client->loginid,
            'max_withdrawal'        => 5,
            'min_withdrawal'        => 0.002,
        },
        {
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
            'paymentagent_loginid'  => $first_pa_loginid,
            'max_withdrawal'        => 2000,
            'min_withdrawal'        => 10,
        }]};

$c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'If token is invalid, then the paymentagents are from broker "CR"');

$params->{token} = $token;
$c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, "If token is valid, then the paymentagents are from client's broker");

$expected_result = {
    'available_countries' => [['id', 'Indonesia',], ['', undef]],
    'list' => [{
            'telephone'             => '+12345678',
            'supported_banks'       => undef,
            'name'                  => 'Hoe',
            'further_information'   => 'Test Information',
            'deposit_commission'    => '0',
            'withdrawal_commission' => '0',
            'currencies'            => 'BTC',
            'email'                 => 'hoe@sample.com',
            'summary'               => 'Test Summary Another',
            'url'                   => 'http://www.sample.com/',
            'paymentagent_loginid'  => $pa_client->loginid,
            'max_withdrawal'        => 5,
            'min_withdrawal'        => 0.002,
        }]};

$params->{args} = {
    paymentagent_list => 'id',
    "currency"        => "BTC"
};
$c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, "If currency is passed then it returns for that currency only");

# TODO:
# I want to test a client with broker 'MF', so the result should be empty. But I cannot, because seems all broker data are in one db on QA and travis
done_testing();
