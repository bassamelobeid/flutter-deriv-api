use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Wallet;

subtest 'initial methods' => sub {

    my $mock_lc_wallet = Test::MockModule->new('LandingCompany::Wallet');
    
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'wallet@deriv.com',
    });
    
    $mock_lc_wallet->mock(get_wallet_for_broker => sub { undef });
    
    throws_ok { BOM::User::Wallet->new({ loginid => $client->loginid }) } qr/Broker code CR is not a wallet/, 'cannot instantiate wallet for non-wallet broker';
    
    my $dummy_config = { landing_company => 'test_lc' };
    $mock_lc_wallet->mock(get_wallet_for_broker => sub { $dummy_config });
    
    my $wallet;
    lives_ok { $wallet = BOM::User::Wallet->new({ loginid => $client->loginid }) } 'can instantiate wallet when broker is a wallet';
    cmp_deeply $wallet->config, $dummy_config, 'wallet->config returns expected data';
    
    my $dummy_lc_data = { testing => 'some value' };
    my $mock_lc_registry = Test::MockModule->new('LandingCompany::Registry');
    
    $mock_lc_registry->mock(get => sub { 
        is shift, 'test_lc', 'LandingCompany::Registry::get called with right lc';
        return $dummy_lc_data;
    });
    
    cmp_deeply $wallet->landing_company, $dummy_lc_data, 'wallet->landing_company returns correct lc data';
};

done_testing;
