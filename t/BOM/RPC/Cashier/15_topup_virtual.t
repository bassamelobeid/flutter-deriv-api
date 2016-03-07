use strict;
use warnings;

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
# start test topup_virtual
################################################################################
my $method = 'topup_virtual';
my $params = {
              language => 'zh_CN',
              token    => '12345'
             };


$c->call_ok($method, $params)->has_error->error_message_is('令牌无效。', 'invalid token');

$test_client->set_status('disabled',1, 'test status');
$test_client->save;
$params->{token} = $token;
$c->call_ok($method, $params)->has_error->error_message_is('令牌无效。', 'invalid token');

