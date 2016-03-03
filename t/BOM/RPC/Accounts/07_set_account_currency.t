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

my $method = 'set_account_currency';
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

$params->{currency} = 'not_allowed';
$c->call_ok($method, $params)->has_error->error_message_is('所提供的货币 not_allowed不可在此账户使用。', 'currency not applicable for this client')->error_code_is('InvalidCurrency', 'error code is correct');

$params->{currency} = 'JPY';
$c->call_ok($method, $params)->has_error->error_message_is('所提供的货币 JPY不可在此账户使用。', 'currency not applicable for this client')->error_code_is('InvalidCurrency', 'error code is correct');

$params->{currency} = 'EUR';
$c->call_ok($method, $params)->has_no_error;
is($c->result->{status}, 1, 'set currency ok');

$test_client->load;
isnt($test_client->default_account, undef, 'default account set');
is($test_client->default_account->currency_code, 'EUR', 'default account updated');

$params->{currency} = 'USD';
$c->call_ok($method, $params)->has_no_error;
is($c->result->{status}, 0, 'set currency failed');

done_testing();

