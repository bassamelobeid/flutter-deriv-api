use strict;
use warnings;

use Test::Most;
use Test::Mojo;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Database::Model::OAuth;
use BOM::Platform::Password;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $m = BOM::Database::Model::AccessToken->new;
my $token = $m->create_token($test_client->loginid, 'test token');

subtest 'new account' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => 12345
    };
    $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');

    $params->{token} = $token;

    BOM::Platform::Runtime->instance->app_config->system->suspend->mt5(1);
    $c->call_ok($method, $params)->has_error->error_message_is('MT5 API calls are suspended.', 'MT5 calls are suspended error message');

    BOM::Platform::Runtime->instance->app_config->system->suspend->mt5(0);

    $params->{args}->{account_type} = undef;
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid account type.', 'Correct error message for undef account type');
    $params->{args}->{account_type} = 'dummy';
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid account type.', 'Correct error message for invalid account type');
    $params->{args}->{account_type} = 'demo';

    my $residence = $test_client->residence;

    $test_client->residence('');
    $test_client->save;

    $c->call_ok($method, $params)->has_error->error_message_is('Please set your country of residence.', 'Residence not set');

    $test_client->residence($residence);
    $test_client->save;

    $params->{args}->{mainPassword}   = 'Abc123';
    $params->{args}->{investPassword} = 'Abc123';
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Investor password cannot be same as main password.', 'Correct error message for same password');

    $params->{args}->{investPassword}   = 'Abc1234';
    $params->{args}->{mt5_account_type} = 'dummy';
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid sub account type.', 'Invalid sub account type error message');

    $params->{args}->{account_type} = 'financial';
    delete $params->{args}->{mt5_account_type};
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid sub account type.', 'Sub account mandatory for financial');

    $params->{args}->{mt5_account_type} = 'cent';
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Please complete financial assessment.', 'Financial assessment mandatory for financial account');

    # MLT client
    $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });

    $m               = BOM::Database::Model::AccessToken->new;
    $token           = $m->create_token($test_client->loginid, 'test token');
    $params->{token} = $token;

    $c->call_ok($method, $params)->has_error->error_message_is('Permission denied.', 'Only costarica and champion fx clients allowed.');

    SKIP: {
        skip "Unable to Retrieve files from PHP MT5 Server Yet";

        # testing unicode name
        $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $test_client->email('test.account@binary.com');
        $test_client->save;
        my $user = BOM::Platform::User->create(
            email    => 'test.account@binary.com',
            password => 'jskjd8292922',
        );
        $user->save;
        $user->add_loginid({loginid => $test_client->loginid});
        $user->save;

        $c     = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
        $m     = BOM::Database::Model::AccessToken->new;
        $token = $m->create_token($test_client->loginid, 'test token 2');

        # set the params
        $params->{token}                  = $token;
        $params->{args}->{account_type}   = 'demo';
        $params->{args}->{country}        = 'mt';
        $params->{args}->{email}          = 'test.account@binary.com';
        $params->{args}->{name}           = 'J\x{c3}\x{b2}s\x{c3}\x{a9}';
        $params->{args}->{investPassword} = 'Abcd1234';
        $params->{args}->{mainPassword}   = 'Efgh4567';
        $params->{args}->{leverage}       = 100;

        # Throttle function limits requests to 1 per minute which may cause
        # consecutive tests to fail without a reset.
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok($method, $params)
            ->has_no_error();
        like($c->response->{rpc_response}->{result}->{login}, qr/[0-9]+/, 'Should return MT5 ID');
    }
};

done_testing();
