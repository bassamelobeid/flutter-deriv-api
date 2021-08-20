use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use BOM::MT5::User::Async;

my $mt5_config = BOM::Config::Runtime->instance->app_config->system->mt5;
$mt5_config->suspend->all(0);
$mt5_config->suspend->real->p01_ts01->all(0);
$mt5_config->suspend->real->p01_ts02->all(0);
$mt5_config->suspend->real->p01_ts03->all(0);
$mt5_config->suspend->real->p01_ts04->all(0);
$mt5_config->suspend->real->p02_ts02->all(0);
$mt5_config->suspend->demo->p01_ts01->all(0);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

my $user = BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

my $mt5 = BOM::TradingPlatform->new(
    platform => 'mt5',
    client   => $client
);
isa_ok($mt5, 'BOM::TradingPlatform::MT5');

$client->account('USD');

$mt5_config->suspend->real->p01_ts01->all(1);
is $mt5->change_password(password => 'test'), undef, 'New MT5 password is set with real suspended and no mt5 accounts';
$mt5_config->suspend->real->p01_ts01->all(0);

ok BOM::User::Password::checkpw('test', $client->user->trading_password), 'MT5 password is OK';

my %mt5_account = (
    demo => {login => 'MTD1000'},
    real => {login => 'MTR1000'},
);

my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
$mock_mt5->mock(
    'get_user',
    sub {
        return Future->done({login => $mt5_account{demo}{login}});
    },
    'password_change',
    sub {
        return Future->done({login => $mt5_account{demo}{login}});
    });

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

$user->add_loginid($mt5_account{demo}{login});

is exception { $mt5->change_password(password => 'test') }, undef, 'No MT5 accounts has no error';

cmp_deeply(
    $mt5->change_password(password => 'secret123'),
    {successful_logins => [$mt5_account{demo}{login}]},
    'Password change request is successful'
);

ok BOM::User::Password::checkpw('secret123', $client->user->trading_password), 'MT5  password is changed';

$mt5_config->suspend->demo->p01_ts01->all(1);
cmp_deeply(
    exception { $mt5->change_password(password => 'secret') },
    {error_code => 'MT5Suspended'},
    'Password change fails with demo server suspended'
);
$mt5_config->suspend->demo->p01_ts01->all(0);

$mock_mt5->mock(
    'get_user',
    sub {
        return Future->fail('NotFound');
    });

cmp_deeply($mt5->change_password(password => 'secret'), {failed_logins => [$mt5_account{demo}{login}]}, 'Password change fails with server error');

$mock_mt5->mock(
    'get_user',
    sub {
        return Future->done({login => $mt5_account{real}{login}});
    },
    'password_change',
    sub {
        return Future->done({login => $mt5_account{real}{login}});
    });

$user->add_loginid($mt5_account{real}{login});

cmp_deeply(
    $mt5->change_password(password => 'secret'),
    {successful_logins => [$mt5_account{demo}{login}, $mt5_account{real}{login}]},
    'Password change request is successful for all MT5 accounts'
);

ok BOM::User::Password::checkpw('secret', $client->user->trading_password), 'MT5 password changed';

$mt5_config->suspend->real->p01_ts01->all(1);
cmp_deeply(
    exception { $mt5->change_password(password => 'secret456') },
    {error_code => 'MT5Suspended'},
    'Password change fails with real server suspended'
);
ok BOM::User::Password::checkpw('secret', $client->user->trading_password), 'MT5 password is not changed with real server suspended';

$mt5_config->suspend->real->p01_ts01->all(0);

$mock_mt5->mock(
    'password_change',
    sub {
        my $self = shift;
        if ($self->{login} eq $mt5_account{demo}{login}) {
            return Future->fail('General');
        }
        return Future->done({login => $self->{login}});
    });

cmp_deeply(
    $mt5->change_password(password => 'secret456'),
    {
        failed_logins     => [$mt5_account{demo}{login}],
        successful_logins => [$mt5_account{real}{login}],
    },
    'Password changed partially when one server has error'
);

ok BOM::User::Password::checkpw('secret', $client->user->trading_password), 'MT5 password is not changed when passwords were partially changed';

$mt5_config->suspend->all(1);
cmp_deeply(exception { $mt5->change_password() }, {error_code => 'MT5Suspended'}, 'Password change fails with all server suspended');
ok BOM::User::Password::checkpw('secret', $client->user->trading_password), 'MT5 password is not changed with all server suspended';
$mt5_config->suspend->all(0);

$mock_mt5->unmock_all();

done_testing();
