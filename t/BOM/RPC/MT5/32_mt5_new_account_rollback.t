use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Test::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use BOM::Config::Runtime;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my $m              = BOM::Platform::Token::API->new;
my %ACCOUNTS       = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS        = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;

subtest 'create mt5 client with different currency' => sub {
    subtest 'define new trade server' => sub {
        my $app_config = BOM::Config::Runtime->instance->app_config;
        note("set app_config->system->mt5->new_trade_server('{\"real02\":{\"all\": \"02\"}}')");
        $app_config->system->mt5->new_trade_server('{"real02":{"all":"02"}}');
        note("set app_config->system->mt5->real02->all(0)");
        $app_config->system->mt5->suspend->real02->all(0);

        my $new_email  = $DETAILS{email};
        my $new_client = create_client('CR', undef, {residence => 'za'});
        my $token      = $m->create_token($new_client->loginid, 'test token 2');
        $new_client->set_default_account('USD');
        $new_client->email($new_email);

        my $user = BOM::User->create(
            email    => $new_email,
            password => 's3kr1t',
        );
        $user->add_client($new_client);

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type => 'gaming',
                email        => $new_email,
                name         => $DETAILS{name},
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            },
        };
        my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
        is $result->{account_type}, 'gaming';
        is $result->{login},        'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\svg_std_usd\01'};

        BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);

        # If you have account on any of the disable server, no new account creation is allowed
        # This will be improved when we have more information on which account is disabled.
        note("set app_config->system->mt5->real02->all(1)");
        $app_config->system->mt5->suspend->real02->all(1);
        $result = $c->call_ok($method, $params)->has_error->error_code_is('MT5CreateUserError')->error_message_is('MT5 is currently unavailable. Please try again later.');

        BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);

        $new_email  = 'abc' . $DETAILS{email};
        $new_client = create_client('CR', undef, {residence => 'za'});
        $token      = $m->create_token($new_client->loginid, 'test token 2');
        $new_client->set_default_account('USD');
        $new_client->email($new_email);

        $user = BOM::User->create(
            email    => $new_email,
            password => 's3kr1t',
        );
        $user->add_client($new_client);

        $params->{token} = $token;
        note("set app_config->system->mt5->new_trade_server('{}')");
        $app_config->system->mt5->new_trade_server('{}');

        $result = $c->call_ok($method, $params)->has_error->error_code_is('MT5REALAPISuspendedError');
    };

    subtest 'define new trade server for south africa synthetic' => sub {
        my $app_config = BOM::Config::Runtime->instance->app_config;
        note("set app_config->system->mt5->new_trade_server('{\"real02\":{\"za\":{\"synthetic\": \"02\"}}}')");
        $app_config->system->mt5->new_trade_server('{"real02":{"za":{"synthetic":"02"}}}');
        note("set app_config->system->mt5->real02->all(0)");
        $app_config->system->mt5->suspend->real02->all(0);

        my $new_email  = 'bds' . $DETAILS{email};
        my $new_client = create_client('CR', undef, {residence => 'za'});
        my $token      = $m->create_token($new_client->loginid, 'test token 2');
        $new_client->set_default_account('USD');
        $new_client->email($new_email);

        my $user = BOM::User->create(
            email    => $new_email,
            password => 's3kr1t',
        );
        $user->add_client($new_client);

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type => 'gaming',
                email        => $new_email,
                name         => $DETAILS{name},
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            },
        };
        my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
        is $result->{account_type}, 'gaming';
        is $result->{login},        'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\svg_std_usd\01'};

        $new_email  = 'abcd' . $DETAILS{email};
        $new_client = create_client('CR', undef, {residence => 'tz'});
        $token      = $m->create_token($new_client->loginid, 'test token 2');
        $new_client->set_default_account('USD');
        $new_client->email($new_email);

        $user = BOM::User->create(
            email    => $new_email,
            password => 's3kr1t',
        );
        $user->add_client($new_client);

        $params->{token} = $token;

        BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);

        $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
        is $result->{account_type}, 'gaming';
        is $result->{login},        'MTR' . $ACCOUNTS{'real\p01_ts01\synthetic\svg_std_usd\01'};

    };
};

done_testing();
