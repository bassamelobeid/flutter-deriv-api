use strict;
use warnings;

use Test::Most;
use Test::Mojo;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use Email::Stuffer::TestLinks;

my $user = BOM::User->create(
    email    => 'test.account@binary.com',
    password => 'jskjd8292922',
);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    citizen        => 'at',
    place_of_birth => 'at'
});
$test_client->set_default_account('USD');
$test_client->save();
$user->add_client($test_client);

my $m = BOM::Database::Model::AccessToken->new;
my $token = $m->create_token($test_client->loginid, 'test token');

subtest 'new account' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => 12345,
        args     => {
            mainPassword   => 'Abc1234d',
            investPassword => 'Abcd12345e',
        },
    };
    $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');

    $params->{token} = $token;

    BOM::Config::Runtime->instance->app_config->system->suspend->mt5(1);
    $c->call_ok($method, $params)->has_error->error_message_is('MT5 API calls are suspended.', 'MT5 calls are suspended error message');

    BOM::Config::Runtime->instance->app_config->system->suspend->mt5(0);

    $params->{args}->{account_type} = undef;
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid account type.', 'Correct error message for undef account type');
    $params->{args}->{account_type} = 'dummy';
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid account type.', 'Correct error message for invalid account type');
    $params->{args}->{account_type} = 'demo';

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    my $citizen = $test_client->citizen;

    $test_client->citizen('');
    $test_client->save;

    $c->call_ok($method, $params)->has_error->error_message_is('Please set citizenship for your account.', 'Citizen not set');

    $test_client->citizen($citizen);
    $test_client->save;

    $params->{args}->{mainPassword}   = 'Abc123';
    $params->{args}->{investPassword} = 'Abc123';
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Investor password cannot be same as main password.', 'Correct error message for same password');

    $params->{args}->{investPassword}   = 'Abc1234';
    $params->{args}->{mt5_account_type} = 'dummy';
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid sub account type.', 'Invalid sub account type error message');

    $params->{args}->{account_type} = 'financial';

    my $pob = $test_client->place_of_birth;

    $test_client->place_of_birth('');
    $test_client->save();

    $c->call_ok($method, $params)->has_error->error_code_is("MissingBasicDetails")->error_message_is("Please fill in your account details")
        ->error_details_is({missing => ["place_of_birth"]});

    $test_client->place_of_birth($pob);
    $test_client->save();

    delete $params->{args}->{mt5_account_type};
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid sub account type.', 'Sub account mandatory for financial');

    $params->{args}->{mt5_account_type} = 'advanced';
    $test_client->aml_risk_classification('high');
    $test_client->save();
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Please complete financial assessment.', 'Financial assessment mandatory for financial account');

    # Non-MLT/CR client
    $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
        citizen     => 'de',
        residence   => 'fr',
    });
    $test_client->set_default_account('EUR');
    $test_client->account_opening_reason("test");
    $test_client->save();

    $user->add_client($test_client);

    $m               = BOM::Database::Model::AccessToken->new;
    $token           = $m->create_token($test_client->loginid, 'test token');
    $params->{token} = $token;

    $c->call_ok($method, $params)
        ->has_error->error_message_is('Permission denied.', 'Only costarica, malta, maltainvest and champion fx clients allowed.');

    SKIP: {
        skip "Unable to Retrieve files from PHP MT5 Server Yet";

        # testing unicode name
        $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $test_client->email('test.account@binary.com');
        $test_client->save;
        my $user = BOM::User->create(
            email    => 'test.account@binary.com',
            password => 'jskjd8292922',
        );
        $user->add_client($test_client);

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
        $c->call_ok($method, $params)->has_no_error();
        like($c->response->{rpc_response}->{result}->{login}, qr/[0-9]+/, 'Should return MT5 ID');
    }
};

done_testing();
