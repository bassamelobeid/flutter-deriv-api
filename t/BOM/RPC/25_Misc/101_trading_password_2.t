use strict;
use warnings;

use Test::Exception;
use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client);
use BOM::Test::Script::DevExperts;
use Test::BOM::RPC::Accounts;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

my ($params, $last_event, $dx_login, $mt5_login);

my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit', sub { $last_event->{$_[0]} = $_[1] });

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);
BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(0);
BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(0);
BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p02_ts02->all(0);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
BOM::User->create(
    email    => 'Pass1234@test.com',
    password => 'test'
)->add_client($client);
$client->account('USD');
my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

# prepare mock mt5 accounts
@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %mt5_accounts = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %mt5_details  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

subtest 'dxtrade' => sub {

    $params->{token} = $token;
    $params->{args}  = {
        platform     => 'dxtrade',
        account_type => 'real',
        market_type  => 'financial',
        password     => 'test',
        currency     => 'USD',
    };

    BOM::Config::Runtime->instance->app_config->system->dxtrade->enable_all_market_type->real(0);

    $c->call_ok('trading_platform_new_account', $params)->has_error->error_code_is('PasswordError')
        ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'weak new password');

    $params->{args}{password} = 'Abcd1234';
    my $dx_fin = $c->call_ok('trading_platform_new_account', $params)->has_no_error->result;
    $dx_login = $dx_fin->{login};

    $params->{args}{market_type} = 'synthetic';
    $params->{args}{password}    = 'wrong';
    $c->call_ok('trading_platform_new_account', $params)->has_error->error_code_is('PasswordError')
        ->error_message_is('That password is incorrect. Please try again.', 'wrong password');

    $params->{args}{password} = 'Abcd1234';
    my $dx_syn = $c->call_ok('trading_platform_new_account', $params)->has_no_error->result;

    BOM::Config::Runtime->instance->app_config->system->dxtrade->enable_all_market_type->demo(1);

    $params->{args}{account_type} = 'demo';
    $params->{args}{market_type}  = 'all';
    my $dx_demo = $c->call_ok('trading_platform_new_account', $params)->has_no_error->result;

    $params->{args}{old_password} = delete $params->{args}{password};
    $params->{args}{new_password} = '1234Abcd';
    $params->{args}{platform}     = 'dxtrade';

    $c->call_ok('trading_platform_password_change', $params)->has_no_error->result;

    cmp_deeply(
        $last_event->{trading_platform_password_changed},
        {
            loginid    => $client->loginid,
            properties => {
                contact_url => ignore(),
                first_name  => $client->first_name,
                type        => 'change',
                logins      => [$dx_login],
                platform    => 'dxtrade'
            }
        },
        'password change event emitted'
    );
    undef $last_event;

    my $mock_dx = Test::MockModule->new('BOM::TradingPlatform::DXTrader');
    $mock_dx->mock('call_api', sub { die if $_[1]{server} eq 'demo' and $_[1]{method} eq 'client_update'; $mock_dx->original('call_api')->(@_) });

    $params->{args}{old_password} = '1234Abcd';
    $params->{args}{new_password} = 'Abcd1234';
    $c->call_ok('trading_platform_password_change', $params)
        ->has_error->error_message_is("Due to a network issue, we couldn't update your MT5 password. Please check your email for more details",
        'error message for failed dx password change');

    ok BOM::User::Password::checkpw('1234Abcd', $client->user->dx_trading_password), 'dxtrade trading password was not changed';

    is $client->user->trading_password, undef, 'mt5 trading password is not set';

    $mock_dx->unmock_all();
};

## TODO: uncomment test below when we bring back a single trading password ##
# subtest 'mixed platforms' => sub {

#     $params->{args}{old_password} = 'Abcd1234';
#     $params->{args}{new_password} = $mt5_details{password}{main};
#     $c->call_ok('trading_platform_password_change', $params)->has_no_error('change trading password to mt5 password');

#     $params->{args} = {
#         account_type => 'gaming',
#         country      => 'mt',
#         email        => $mt5_details{email},
#         name         => $mt5_details{name},
#         mainPassword => $mt5_details{password}{main},
#         leverage     => 100,
#     };

#     my $result = $c->call_ok('mt5_new_account', $params)->has_no_error('create mt5 account')->result;
#     $mt5_login = $result->{login};

#     my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
#     $mock_mt5->mock(password_change => sub { Future->done(1) });

#     undef $last_event;
#     $params->{args}{old_password} = $mt5_details{password}{main};
#     $params->{args}{new_password} = '1234Abcd';
#     $c->call_ok('trading_platform_password_change', $params)->has_no_error('change trading password with both accounts');

#     ok BOM::User::Password::checkpw('1234Abcd', $client->user->trading_password), 'trading password was changed';

#     cmp_deeply(
#         $last_event->{trading_platform_password_changed},
#         {
#             loginid    => $client->loginid,
#             properties => {
#                 contact_url       => ignore(),
#                 first_name        => $client->first_name,
#                 type              => 'change',
#                 dx_logins         => [$dx_login],
#                 mt5_logins        => [$mt5_login],
#                 dxtrade_available => 1,
#             }
#         },
#         'password change event emitted'
#     );
#     undef $last_event;

#     $mock_mt5->mock(
#         password_change => sub {
#             return Future->fail({
#                 code => 'General',
#             });
#         });

#     $params->{args}{old_password} = '1234Abcd';
#     $params->{args}{new_password} = 'Abcd1234';
#     $c->call_ok('trading_platform_password_change', $params)
#         ->has_error->error_message_is(
#         "Due to a network issue, we couldn't update the password for some of your accounts. Please check your email for more details.",
#         'error message for single failed login');

#     ok BOM::User::Password::checkpw('Abcd1234', $client->user->trading_password), 'trading password was changed';

#     cmp_deeply(
#         $last_event->{trading_platform_password_change_failed},
#         {
#             loginid    => $client->loginid,
#             properties => {
#                 contact_url           => ignore(),
#                 first_name            => $client->first_name,
#                 type                  => 'change',
#                 successful_dx_logins  => [$dx_login],
#                 failed_dx_logins      => undef,
#                 successful_mt5_logins => undef,
#                 failed_mt5_logins     => [$mt5_login],
#                 dxtrade_available     => 1,
#             }
#         },
#         'password failed change event emitted'
#     );
#     undef $last_event;

#     my $mock_dx = Test::MockModule->new('BOM::TradingPlatform::DXTrader');
#     $mock_dx->mock('call_api', sub { die if $_[1]{method} eq 'client_update'; $mock_dx->original('call_api')->(@_) });

#     $params->{args}{old_password} = 'Abcd1234';
#     $params->{args}{new_password} = '1234Abcd';

#     $c->call_ok('trading_platform_password_change', $params)
#         ->has_error->error_message_is(
#         "Due to a network issue, we couldn't update the password for some of your accounts. Please check your email for more details.",
#         'error message for multiple failed logins');

#     ok BOM::User::Password::checkpw('Abcd1234', $client->user->trading_password), 'trading password was not changed';

#     cmp_deeply(
#         $last_event->{trading_platform_password_change_failed},
#         {
#             loginid    => $client->loginid,
#             properties => {
#                 contact_url           => ignore(),
#                 first_name            => $client->first_name,
#                 type                  => 'change',
#                 successful_dx_logins  => undef,
#                 failed_dx_logins      => [$dx_login],
#                 successful_mt5_logins => undef,
#                 failed_mt5_logins     => [$mt5_login],
#                 dxtrade_available     => 1,
#             }
#         },
#         'password failed change event emitted'
#     );
#     undef $last_event;

#     $mock_dx->unmock_all();

# };

# subtest 'archived mt5 account' => sub {
#     my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
#     $mock_mt5->mock(
#         password_change => sub { Future->done(1) },
#         get_user        => sub {
#             Future->fail({
#                 'code'  => 'NotFound',
#                 'error' => 'Not found.'
#             });
#         },
#     );

#     $params->{args}{old_password} = 'Abcd1234';
#     $params->{args}{new_password} = '1234Abcd';

#     $c->call_ok('trading_platform_password_change', $params)->has_no_error('change trading password with archived mt5 account');

#     ok BOM::User::Password::checkpw('1234Abcd', $client->user->trading_password), 'trading password was changed';

#     cmp_deeply(
#         $last_event->{trading_platform_password_changed},
#         {
#             loginid    => $client->loginid,
#             properties => {
#                 contact_url       => ignore(),
#                 first_name        => $client->first_name,
#                 type              => 'change',
#                 dx_logins         => [$dx_login],
#                 mt5_logins        => undef,
#                 dxtrade_available => 1,
#             }
#         },
#         'password change event emitted'
#     );
#     undef $last_event;
# };

subtest 'mlt client' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
        email       => 'mlt@test.com'
    });
    BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $client->account('USD');
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    my $params = {
        language => 'EN',
        args     => {
            verify_email => $client->email,
            type         => 'trading_platform_mt5_password_reset'
        }};

    $c->call_ok('verify_email', $params)->has_no_error;

    cmp_deeply(
        $last_event->{trading_platform_password_reset_request},
        {
            loginid    => $client->loginid,
            properties => {
                first_name       => $client->first_name,
                code             => ignore(),
                verification_url => ignore(),
                platform         => 'mt5',
            }
        },
        'password reset request event emitted'
    );
    undef $last_event;

    $params = {
        token => $token,
        args  => {
            trading_platform_password_change => 1,
            new_password                     => 'Abcd1234',
            platform                         => 'mt5'
        }};

    $c->call_ok('trading_platform_password_change', $params)->has_no_error->result;

    cmp_deeply(
        $last_event->{trading_platform_password_changed},
        {
            loginid    => $client->loginid,
            properties => {
                contact_url => ignore(),
                first_name  => $client->first_name,
                type        => 'change',
                logins      => undef,
                platform    => 'mt5',
            }
        },
        'password change event emitted'
    );
    undef $last_event;

};

done_testing();
