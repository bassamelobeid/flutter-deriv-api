use strict;
use warnings;

use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $loginid = $client->loginid;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $loginid,
    email   => $email
)->token;

$client->deposit_virtual_funds;
my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
subtest 'buy' => sub {
    my $params = {language => 'ZH_CN', token => 'invalid token'};
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'invalid token')
        ->error_message_is('令牌无效。', 'invalid token');

    $client->set_status('disabled', 1, 'disabled for test');
    $client->save;
    $params->{token} = $token;
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'AuthorizationRequired')
      ->error_message_is('请登录', 'please login');

    ok(1);
};

done_testing();
