use strict;
use warnings;

use List::Util qw(first);
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
    demo => {
        login    => 'MTD1000',
        main     => 'main1',
        investor => 'investor1'
    },
    real => {
        login    => 'MTR1000',
        main     => 'main2',
        investor => 'investor2'
    },
    real2 => {
        login    => 'MTR40000000',
        main     => 'main3',
        investor => 'investor3'
    },
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
    },
    # we call password_check to compare the new main password against investor password;
    # in normal circumstances it should fail, meanin that the new main password is not the same as the investor password.
    'password_check' => Future->fail({code => 'InvalidPassword'}));

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
cmp_deeply(exception { $mt5->change_password(password => 'secret') }, undef, 'Password change fails with demo server suspended');
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
cmp_deeply(exception { $mt5->change_password(password => 'secret456') }, undef, 'Password change fails with real server suspended');
ok BOM::User::Password::checkpw('secret', $client->user->trading_password), 'MT5 password is not changed with real server suspended';

$mt5_config->suspend->real->p01_ts01->all(0);

subtest 'MT5 demo server suspended' => sub {
    $mt5_config->suspend->demo->p01_ts01->all(1);
    cmp_deeply(exception { $mt5->change_password(password => 'secret') }, undef, 'Password change fails with demo server suspended');
    $mt5_config->suspend->demo->p01_ts01->all(0);
};

subtest 'MT5 real server suspended' => sub {
    $mt5_config->suspend->real->p01_ts01->all(1);
    cmp_deeply(exception { $mt5->change_password(password => 'secret') }, undef, 'Password change fails with demo server suspended');
    $mt5_config->suspend->real->p01_ts01->all(0);
};

subtest 'MT5 other server suspend' => sub {
    $mt5_config->suspend->demo->p01_ts02->all(1);
    $mt5_config->suspend->real->p01_ts03->all(1);

    cmp_deeply(
        $mt5->change_password(password => 'secret'),
        {successful_logins => [$mt5_account{demo}{login}, $mt5_account{real}{login}]},
        'Accounts only in demo->p01_ts01 and real->p01_ts01 , suspending other trade server with not affect anything'
    );

    $mt5_config->suspend->demo->p01_ts02->all(0);
    $mt5_config->suspend->real->p01_ts03->all(0);
};

subtest 'do not allow change password when one of the user group trade server is down' => sub {
    $user->add_loginid($mt5_account{real2}{login});

    $mock_mt5->mock(
        'get_user',
        sub {
            return Future->fail({login => $mt5_account{real2}{login}});
        },
        'password_change',
        sub {
            return Future->fail({login => $mt5_account{real2}{login}});
        });

    $mt5_config->suspend->real->p01_ts03->all(1);
    cmp_deeply(exception { $mt5->change_password(password => 'secret456') }, undef, 'Password change fails with real server suspended');

    ok BOM::User::Password::checkpw('secret', $client->user->trading_password),
        'MT5 password is not changed when one of the user group trade server is down';
    $mt5_config->suspend->real->p01_ts03->all(0);
};

$mt5_config->suspend->all(1);
cmp_deeply(exception { $mt5->change_password() }, undef, 'Password change fails with all server suspended');
ok BOM::User::Password::checkpw('secret', $client->user->trading_password), 'MT5 password is not changed with all server suspended';
$mt5_config->suspend->all(0);

subtest 'same password' => sub {
    $mt5_config->suspend->real->p01_ts01->all(0);
    $mt5_config->suspend->demo->p01_ts01->all(0);
    $mt5_config->suspend->all(0);

    $mock_mt5->mock(
        'get_user' => sub {
            my $mt5_loginid = shift;
            return Future->done({login => $mt5_loginid});
        },
        'password_change',
        sub {
            my $args = shift;
            return Future->done({login => $args->{login}});
        },
        'password_check' => sub {
            my $args = shift;

            my $found = first { $mt5_account{$_}->{login} eq $args->{login} } (keys %mt5_account);
            return Future->fail({code => 'NotFound'}) unless $found;

            my $found_account = $mt5_account{$found};
            return Future->done if $found_account->{$args->{type}} eq $args->{password};

            return Future->fail({code => 'InvalidPassword'});
        });

    is_deeply exception { $mt5->change_password(password => 'investor1') }, {code => 'SameAsInvestorPassword'},
        'Correct error when new password is the same as the investor password';
    is_deeply exception { $mt5->change_password(password => 'investor2') }, {code => 'SameAsInvestorPassword'},
        'Correct error when new password is the same as the investor password of the sibling MT5 account';
    is exception { $mt5->change_password(password => 'new password') }, undef,
        'Password is changed successfully when it is different from investor passwords';

    my $account_id = $mt5_account{demo}->{login};
    my %args       = (
        new_password => 'main1',
        account_id   => $account_id,
    );
    is_deeply exception { $mt5->change_investor_password(%args)->get }, {code => 'SameAsMainPassword'},
        'Correct error when new password is the same as the main password of the same account';
    $args{new_password} = 'main2';
    is exception { $mt5->change_investor_password(%args)->get }, undef, 'Succeeds with the main password of the sibling account - it is fine';

    $args{new_password} = 'new password';
    $args{old_password} = 'invalid';
    is_deeply exception { $mt5->change_investor_password(%args)->get }, {code => 'InvalidPassword'}, 'Correct error when old password is incorrect';

    $args{old_password} = 'investor1';
    is exception { $mt5->change_investor_password(%args)->get }, undef, 'Succeeds when the old password is correct';

};

$mock_mt5->unmock_all();

done_testing();
