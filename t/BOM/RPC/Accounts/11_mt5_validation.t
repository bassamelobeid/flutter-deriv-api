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
};

done_testing();
