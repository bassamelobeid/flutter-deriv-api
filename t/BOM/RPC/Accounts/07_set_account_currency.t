use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use utf8;
use Data::Dumper;
use BOM::Config::Runtime;

my $email       = 'dummy@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

is $test_client->default_account, undef, 'new client has no default account';

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $method = 'set_account_currency';
my $params = {
    language => 'EN',
    token    => 12345
};
$c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');
$params->{token} = $token;
$test_client->status->set('disabled', 1, 'test disabled');
$c->call_ok($method, $params)->has_error->error_message_is('This account is unavailable.', 'check invalid token');
$test_client->status->clear_disabled;

$params->{currency} = 'not_allowed';
$c->call_ok($method, $params)
    ->has_error->error_message_is('The provided currency not_allowed is not applicable for this account.', 'currency not applicable for this client')
    ->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');

$params->{currency} = 'JPY';
$c->call_ok($method, $params)
    ->has_error->error_message_is('The provided currency JPY is not applicable for this account.', 'currency not applicable for this client')
    ->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');

BOM::Config::Runtime->instance->app_config->system->suspend->cryptocashier(1);
$params->{currency} = 'BTC';
$c->call_ok($method, $params)
    ->has_error->error_message_is('The provided currency BTC is not selectable at the moment.', 'currency not applicable for this client')
    ->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');
BOM::Config::Runtime->instance->app_config->system->suspend->cryptocashier(0);

$params->{currency} = 'EUR';
$c->call_ok($method, $params)->has_no_error;
is($c->result->{status}, 1, 'set currency ok');

# here I tried $test_client->load directly but failed
# But recreating the client will work. weird
my $client = BOM::User::Client->new({loginid => $test_client->loginid});

isnt($client->default_account, undef, 'default account set');
is($client->default_account->currency_code, 'EUR', 'default account updated');

$params->{currency} = 'USD';
$c->call_ok($method, $params)->has_no_error;
is($c->result->{status}, 0, 'set currency failed');

done_testing();

