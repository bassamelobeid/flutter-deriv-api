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
$test_client->set_status('disabled', 1, 'test disabled');
$test_client->save;
$c->call_ok($method, $params)->has_error->error_message_is('此账户不可用。', 'check invalid token');
$test_client->clr_status('disabled');
$test_client->save;
