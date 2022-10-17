use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Wallet;

subtest 'initial methods' => sub {

    my $mock_client = Test::MockModule->new('BOM::User::Client');

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'wallet_cr@deriv.com',
    });

    $mock_client->redefine(get_class_by_broker_code => 'BOM::User::Client');

    throws_ok { BOM::User::Wallet->new({loginid => $client->loginid}) } qr/Broker code CR is not a wallet/,
        'cannot instantiate wallet for non-wallet broker';

    my $client_client = BOM::User::Client->get_client_instance($client->loginid);
    isa_ok($client_client, 'BOM::User::Client', 'get_client_instance()');
    ok(!$client_client->is_wallet, 'trading client is_wallet is false');
    ok($client_client->can_trade,  'tradint client can_trade is true');

    $mock_client->redefine(get_class_by_broker_code => 'BOM::User::Wallet');
    my $wallet;
    lives_ok { $wallet = BOM::User::Wallet->new({loginid => $client->loginid}) } 'can instantiate wallet when broker is a wallet';

    my $wallet_client = BOM::User::Client->get_client_instance($wallet->loginid);
    isa_ok($wallet_client, 'BOM::User::Wallet', 'get_client_instance()');
    ok($wallet_client->is_wallet,     'wallet client is_wallet is true');
    ok(!$wallet_client->can_trade,    'wallet client can_trade is false');
    ok(!$wallet_client->is_affiliate, 'wallet client is_affiliate is false');

    $mock_client->unmock_all;
};

done_testing;
