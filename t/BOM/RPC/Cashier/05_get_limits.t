use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/../../../lib";
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::SessionCookie;
use BOM::System::Password;
use utf8;
use Data::Dumper;

################################################################################
# init test data
################################################################################

my $email       = 'raunak@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::System::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                                                                             broker_code => 'CR',
                                                                            });
$test_client->email($email);
$test_client->save;

my $test_loginid = $test_client->loginid;
my $user         = BOM::Platform::User->create(
                                               email    => $email,
                                               password => $hash_pwd
                                              );
$user->save;

my $token = BOM::Platform::SessionCookie->new(
                                              loginid => $test_loginid,
                                              email   => $email
                                             )->token;

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
################################################################################
# start test
################################################################################
my $method = 'get_limits';
my $params = {language => 'zh_CN', token => '12345'};
$c->call_ok($method, $params)->has_error->error_message_is('令牌无效。', 'invalid token');
$test_client->set_status('disabled', 1, 'test');
$test_client->save;
$params->{token} = $token;
$c->call_ok($method, $params)->has_error->error_message_is('此账户不可用。', 'invalid token');
$test_client->clr_status('disabled');
$test_client->set_status('cashier_locked',1, 'test');
$test_client->save;
$c->call_ok($method, $params)->has_error->error_message_is('此账户不可用。', 'invalid token');

done_testing();

