use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::SessionCookie;
use utf8;
use Data::Dumper;

my $email       = 'dummy@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

is $test_client->default_account, undef, 'new client has no default account';

my $token = BOM::Platform::SessionCookie->new(
    loginid => $test_client->loginid,
    email   => $email
)->token;

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $method = 'authorize';
my $params = {
    language => 'zh_CN',
    token    => 12345
};

$c->call_ok($method, $params)->has_error->error_message_is('令牌无效。', 'check invalid token');
$params->{token} = $token;
my $expected_result = {
    fullname             => $test_client->full_name,
    loginid              => $test_client->loginid,
    balance              => 0,
    currency             => '',
    email                => 'dummy@binary.com',
    account_id           => '',
    landing_company_name => 'costarica',
    country              => 'id',
    scopes               => [qw(read trade admin payments)],
    is_virtual           => 0,
};
$c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is correct');

$test_client->set_default_account('USD');
$test_client->save;
$test_client->payment_free_gift(
    currency => 'USD',
    amount   => 1000,
    remark   => 'free gift',
);
$expected_result->{account_id} = $test_client->default_account->id;
$expected_result->{currency}   = 'USD';
$expected_result->{balance}    = '1000.0000';
$c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is correct');

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;
my $token_vr = BOM::Platform::SessionCookie->new(
    loginid => $test_client_vr->loginid,
    email   => $email
)->token;
$params->{token} = $token_vr;
is($c->call_ok($method, $params)->has_no_error->result->{is_virtual}, 1, "is_virtual is true if client is virtual");
done_testing();
