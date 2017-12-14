use strict;
use warnings;

use Test::Most;
use Test::Mojo;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::MT5::User;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

# Setup a test user
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email('test.account@binary.com');
$test_client->save;

my $user = BOM::Platform::User->create(
    email    => 'test.account@binary.com',
    password => 's3kr1t',
);
$user->save;
$user->add_loginid({loginid => $test_client->loginid});
$user->save;

my $m = BOM::Database::Model::AccessToken->new;
my $token = $m->create_token($test_client->loginid, 'test token');

@BOM::MT5::User::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

subtest 'new account' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type   => 'demo',
            country        => 'mt',
            email          => 'test.account@binary.com',
            name           => 'Test',
            investPassword => 'Abcd1234',
            mainPassword   => 'Efgh4567',
            leverage       => 100,
        },
    };
    $c->call_ok($method, $params)
        ->has_no_error('no error for mt5_new_account');
};

done_testing();
