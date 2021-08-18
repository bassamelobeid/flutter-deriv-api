use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use BOM::Config::Runtime;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %accounts       = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %details        = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;

# Create user
my $test_client    = create_client('CR');
my $test_client_vr = create_client('VRTC');

$test_client->email($details{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id(1);

$test_client_vr->email($details{email});
$test_client_vr->set_default_account('USD');

$test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
$test_client->save;

$test_client_vr->save;

my $password = 'Hello123';
my $hash_pwd = BOM::User::Password::hashpw($password);
my $user     = BOM::User->create(
    email    => $details{email},
    password => $hash_pwd,
);
$user->add_client($test_client);
$user->add_client($test_client_vr);

my %basic_details = (
    place_of_birth            => "af",
    tax_residence             => "af",
    tax_identification_number => "1122334455",
    account_opening_reason    => "testing"
);

$test_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
$test_client->save;

my $m        = BOM::Platform::Token::API->new;
my $token    = $m->create_token($test_client->loginid,    'test token');
my $token_vr = $m->create_token($test_client_vr->loginid, 'test token');

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);

my $method = 'mt5_new_account';
subtest 'mt5 new account - no trading password' => sub {
    my $password = $details{password}{main};

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $password,
            leverage     => 100,
        }};

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    subtest 'should fail when password format is incorrect' => sub {
        $params->{args}->{mainPassword} = 's3kr1t';
        $c->call_ok($method, $params)->has_error->error_code_is('IncorrectMT5PasswordFormat')
            ->error_message_is("Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.",
            'Correct error message when user password did not pass mt5 password validation');
    };

    subtest 'should not save trading password on dry_run' => sub {
        $params->{args}->{mainPassword} = $password;
        $params->{args}->{dry_run}      = 1;
        $c->call_ok($method, $params)->has_no_error('financial account successfully created');
        is $test_client->user->trading_password, undef, 'trading password is not saved';
    };

    subtest 'should not save trading password when MT5 server is suspended' => sub {
        delete $params->{args}->{dry_run};
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(1);

        $c->call_ok($method, $params)->has_error->error_code_is('MT5CreateUserError');
        is $test_client->user->trading_password, undef, 'trading password is not saved';

        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    subtest 'can create new mt5 account' => sub {
        $user->update_trading_password($password);

        my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
        is $result->{account_type}, 'gaming';
        is $result->{login},        'MTR' . $accounts{'real\p01_ts03\synthetic\svg_std_usd\01'};
    };
};

subtest 'mt5 new account - has trading password' => sub {
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'financial',
            email            => $details{email},
            name             => $details{name},
            mainPassword     => 'Abcd1234',
            leverage         => 100,
        }};

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    subtest 'should fail when password format is incorrect' => sub {
        $params->{args}->{mainPassword} = 's3kr1t';
        $c->call_ok($method, $params)->has_error->error_code_is('IncorrectMT5PasswordFormat')
            ->error_message_is("Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.",
            'Correct error message when password did not pass mt5 password validation');
    };

    subtest 'should fail when trading password incorrect' => sub {
        $params->{args}->{mainPassword} = 'Random123';
        $c->call_ok($method, $params)->has_error->error_code_is('PasswordError')
            ->error_message_is("That password is incorrect. Please try again.", 'Correct error message when user entered the wrong trading_password');
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    subtest 'can create new mt5 account when using the correct trading password' => sub {
        $params->{args}->{mainPassword} = $details{password}{main};
        my $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'financial', 'account_type=financial';
        is $result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\svg_std_usd'}, 'created in group real\p01_ts01\financial\svg_std_usd';
    };
};

done_testing();
