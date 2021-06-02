use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::TradingPlatform;
use BOM::Config::Runtime;

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

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

is exception { $dxtrader->change_password(password => 'test')->get }, undef, 'No DXClient has no error';

cmp_deeply(exception { $dxtrader->change_password()->get }, {error_code => 'PasswordRequired'}, 'Password is required',);

my $acc = $dxtrader->new_account(
    account_type => 'demo',
    password     => 'test',
    market_type  => 'financial',
    currency     => 'USD',
);

cmp_deeply($dxtrader->change_password(password => 'secret')->get, {successful_dx_logins => [$acc->{login}]}, 'Password change request is successful',
);

done_testing();
