use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::TradingPlatform;
use BOM::Test::Helper::Client;

subtest "deposit from CR account to DerivEZ" => sub {
    my %derivez_account = (
        real => {login => 'EZR80000000'},
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $user   = BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $user->add_loginid($derivez_account{real}{login});
    BOM::Test::Helper::Client::top_up($client, $client->currency, 10);

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform => 'derivez',
        client   => $client
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    my $args = {
        amount       => 10,
        from_account => $client->loginid,
        to_account   => $derivez_account{real}{login}};
    my $mock_derivez = Test::MockModule->new('BOM::TradingPlatform::DerivEZ');
    $mock_derivez->mock('deposit', sub { return Future->done({status => 1, transaction_id => '88'}); });
    cmp_deeply(
        $derivez->deposit($args)->get,
        {
            status         => 1,
            transaction_id => '88'
        },
        'can withdraw from derivez to cr'
    );

    $mock_derivez->unmock_all();
};

done_testing();
