use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::TradingPlatform;

# List of mt5 accounts
my %mt5_account = (
    demo  => {login => 'MTD1000'},
    real  => {login => 'MTR1000'},
    real2 => {login => 'MTR40000000'},
);

subtest 'check if mt5 trading platform get_accounts will return the correct user' => sub {
    # Creating the account
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $user   = BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $user->add_loginid($mt5_account{demo}{login});
    $user->add_loginid($mt5_account{real}{login});
    $user->add_loginid($mt5_account{real2}{login});

    # Check for MT5 TradingPlatform
    my $mt5 = BOM::TradingPlatform->new(
        platform => 'mt5',
        client   => $client
    );
    isa_ok($mt5, 'BOM::TradingPlatform::MT5');

    # We need to mock the module to get a proper response
    my $mock_mt5           = Test::MockModule->new('BOM::TradingPlatform::MT5');
    my @check_mt5_accounts = ($mt5_account{demo}{login}, $mt5_account{real}{login}, $mt5_account{real2}{login});
    $mock_mt5->mock('get_accounts', sub { return Future->done(\@check_mt5_accounts); });

    cmp_deeply($mt5->get_accounts->get, \@check_mt5_accounts, 'can get accounts using get_accounts');

    $mock_mt5->unmock_all();
};

done_testing();
