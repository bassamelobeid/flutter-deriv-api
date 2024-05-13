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
        market_type  => 'all',
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

done_testing();
