use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/../../../lib";
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::SessionCookie;
use Test::MockModule;
use utf8;

################################################################################
# init test data
################################################################################

my $email       = 'raunak@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;
my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;
my $test_loginid = $test_client->loginid;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $test_loginid,
    email   => $email
)->token;
my $token_vr = BOM::Platform::SessionCookie->new(
    loginid => $test_client_vr->loginid,
    email   => $email
)->token;
my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
################################################################################
# start test
################################################################################
my $method = 'get_limits';
my $params = {
    language => 'zh_CN',
    token    => '12345'
};
$c->call_ok($method, $params)->has_error->error_message_is('令牌无效。', 'invalid token');
$test_client->set_status('disabled', 1, 'test');
$test_client->save;
$params->{token} = $token;
$c->call_ok($method, $params)->has_error->error_message_is('此账户不可用。', 'invalid token');
$test_client->clr_status('disabled');
$test_client->set_status('cashier_locked', 1, 'test');
$test_client->save;
$c->call_ok($method, $params)->has_error->error_message_is('对不起，此功能不可用。', 'invalid token');
$test_client->clr_status('cashier_locked');
$test_client->save;
my $expected_result = {
    'account_balance'                     => '300000',
    'num_of_days'                         => '30',
    'withdrawal_for_x_days_monetary'      => '0',
    'remainder'                           => '10000',
    'open_positions'                      => '60',
    'lifetime_limit'                      => '10000',
    'num_of_days_limit'                   => '10000',
    'withdrawal_since_inception_monetary' => '0',
    'daily_turnover'                      => '200000',
    'payout'                              => '200000'
};

$c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

# It is difficult to set client as fully authenticated, so I mocked it here
#my $mocked_client = Test::MockModule->new('BOM::Platform::Client');
#$mocked_client->mock('client_fully_authenticated', sub{1});
$test_client->set_authentication('ID_192')->status('pass');
$test_client->save;
$expected_result = {
    'lifetime_limit'    => '99999999',
    'account_balance'   => '300000',
    'num_of_days_limit' => '99999999',
    'num_of_days'       => '30',
    'daily_turnover'    => '500000',
    'open_positions'    => '60',
    'payout'            => '500000'
};

$c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');

#add an expired document
my ($doc) = $test_client->add_client_authentication_document({
    document_type              => "Passport",
    document_format            => "PDF",
    document_path              => '/tmp/test.pdf',
    expiration_date            => '2008-10-10',
    authentication_method_code => 'ID_DOCUMENT'
});
$test_client->save;
$c->call_ok($method, $params)->has_error->error_message_is('对不起，此功能不可用。', 'invalid token');

$params->{token} = $token_vr;
$c->call_ok($method, $params)->has_error->error_message_is('对不起，此功能不可用。', 'invalid token');

done_testing();

