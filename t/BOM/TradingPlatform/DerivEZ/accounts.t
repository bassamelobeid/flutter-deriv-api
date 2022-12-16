use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::TradingPlatform;

subtest "create new derivez account" => sub {
    my %derivez_account = (
        demo => {login => 'EZD40100000'},
        real => {login => 'EZR80000000'},
    );
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $user   = BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $user->add_loginid($derivez_account{demo}{login});
    $user->add_loginid($derivez_account{real}{login});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform => 'derivez',
        client   => $client
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');
    my $mock_derivez           = Test::MockModule->new('BOM::TradingPlatform::DerivEZ');
    my @check_derivez_accounts = ($derivez_account{demo}{login}, $derivez_account{real}{login});
    $mock_derivez->mock('get_accounts', sub { return Future->done(\@check_derivez_accounts); });

    cmp_deeply($derivez->get_accounts->get, \@check_derivez_accounts, 'can get accounts using get_accounts');

    $mock_derivez->unmock_all();
};

done_testing();
