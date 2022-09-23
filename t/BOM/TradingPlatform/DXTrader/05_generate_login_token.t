use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use BOM::Rules::Engine;

my $dxconfig = BOM::Config::Runtime->instance->app_config->system->dxtrade;
$dxconfig->suspend->all(0);
$dxconfig->suspend->demo(0);
$dxconfig->suspend->real(0);
$dxconfig->enable_all_market_type->demo(1);
$dxconfig->enable_all_market_type->real(0);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

$client->account('USD');

my $dxtrader = BOM::TradingPlatform->new(
    platform    => 'dxtrade',
    rule_engine => BOM::Rules::Engine->new(client => $client),
    client      => $client
);

cmp_deeply(exception { $dxtrader->generate_login_token('') },     {error_code => 'DXNoServer'},  'missing server param');
cmp_deeply(exception { $dxtrader->generate_login_token('demo') }, {error_code => 'DXNoAccount'}, 'no demo account');
cmp_deeply(exception { $dxtrader->generate_login_token('real') }, {error_code => 'DXNoAccount'}, 'no real account');

my $account = $dxtrader->new_account(
    account_type => 'demo',
    password     => 'test',
    market_type  => 'all',
);

is $dxtrader->generate_login_token('demo'), $account->{login} . '_dummy_token', 'generate token (dummy)';
cmp_deeply(exception { $dxtrader->generate_login_token('real') }, {error_code => 'DXNoAccount'}, 'no real account');

$dxconfig->suspend->all(1);
cmp_deeply(exception { $dxtrader->generate_login_token('demo') }, {error_code => 'DXSuspended'}, 'all suspended');
$dxconfig->suspend->all(0);

$dxconfig->suspend->demo(1);
cmp_deeply(exception { $dxtrader->generate_login_token('demo') }, {error_code => 'DXServerSuspended'}, 'demo suspended');
$dxconfig->suspend->demo(0);

$dxconfig->suspend->real(1);
cmp_deeply(exception { $dxtrader->generate_login_token('demo') }, undef, 'suspend real does not affect demo');
$dxconfig->suspend->real(0);

my $dxtrader_mock = Test::MockModule->new('BOM::TradingPlatform::DXTrader');
$dxtrader_mock->mock(call_api => undef);

cmp_deeply(exception { $dxtrader->generate_login_token('demo') }, {error_code => 'DXTokenGenerationFailed'}, 'api failure');

done_testing();
