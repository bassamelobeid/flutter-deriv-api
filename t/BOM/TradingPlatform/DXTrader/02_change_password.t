use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use Test::MockModule;

my $dxconfig = BOM::Config::Runtime->instance->app_config->system->dxtrade;
$dxconfig->suspend->all(0);
$dxconfig->suspend->demo(0);
$dxconfig->suspend->real(0);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

my $dxtrader = BOM::TradingPlatform->new(
    platform => 'dxtrade',
    client   => $client
);
isa_ok($dxtrader, 'BOM::TradingPlatform::DXTrader');

$client->account('USD');

$dxconfig->suspend->real(1);
cmp_deeply($dxtrader->change_password(password => 'secret'),
    undef, 'Password change request is successful with real server suspended and no DXClient');
$dxconfig->suspend->real(0);

is exception { $dxtrader->change_password(password => 'test') }, undef, 'No DXClient has no error';

ok BOM::User::Password::checkpw('test', $client->user->dx_trading_password), 'DX password is set';

my $acc = $dxtrader->new_account(
    account_type => 'demo',
    password     => 'test',
    market_type  => 'financial',
    currency     => 'USD',
);

cmp_deeply($dxtrader->change_password(password => 'secret'), {successful_logins => [$acc->{login}]}, 'Password change request is successful');

ok BOM::User::Password::checkpw('secret', $client->user->dx_trading_password), 'DX password is changed';

$dxconfig->suspend->real(1);
cmp_deeply(
    $dxtrader->change_password(password => 'secret1'),
    {successful_logins => [$acc->{login}]},
    'Password change is successful with real server suspended'
);
ok BOM::User::Password::checkpw('secret1', $client->user->dx_trading_password), 'DX password is changed with real server suspended';
$dxconfig->suspend->real(0);

$dxconfig->suspend->demo(1);
cmp_deeply(
    exception { $dxtrader->change_password(password => 'secret') },
    {error_code => 'DXServerSuspended'},
    'Password change fails with demo server suspended'
);
ok BOM::User::Password::checkpw('secret1', $client->user->dx_trading_password), 'DX password is not changed with demo server suspended';
$dxconfig->suspend->demo(0);

my $acc_real = $dxtrader->new_account(
    account_type => 'real',
    password     => 'secret',
    market_type  => 'financial',
    currency     => 'USD',
);

cmp_deeply($dxtrader->change_password(password => 'secret2'), {successful_logins => [$acc_real->{login}]}, 'Password change request is successful');
ok BOM::User::Password::checkpw('secret2', $client->user->dx_trading_password), 'DX password is changed';

my $dxtrader_mock = Test::MockModule->new('BOM::TradingPlatform::DXTrader');
$dxtrader_mock->mock(
    'call_api',
    sub {
        my $self = shift;
        if ($self->account_servers('real')) {
            die 'Error';
        }
    });

cmp_deeply($dxtrader->change_password(password => 'secret3'), {failed_logins => [$acc->{login}]}, 'Password change fails with call_api error');
ok BOM::User::Password::checkpw('secret2', $client->user->dx_trading_password), 'DX password is not changed with call_api error';

$dxconfig->suspend->all(1);
cmp_deeply(exception { $dxtrader->change_password() }, {error_code => 'DXSuspended'}, 'Password change fails with all dxtrade suspended');
ok BOM::User::Password::checkpw('secret2', $client->user->dx_trading_password), 'DX password is not changed with all dxtrade suspended';
$dxconfig->suspend->all(0);

$dxtrader_mock->unmock_all();

done_testing();
