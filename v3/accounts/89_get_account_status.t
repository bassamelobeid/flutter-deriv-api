use strict;
use warnings;
use Test::More;
use Test::Deep;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;
use await;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_wsapi_test();

subtest 'Onfido country code' => sub {
    my ($vr_client, $user) = create_vr_account({
        email           => 'addr@binary.com',
        client_password => 'abc123',
        residence       => 'br',
    });

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $user->add_client($client);

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'Emptiness' => sub {
        $client->place_of_birth('');
        $client->residence('');
        $client->save;

        ok !$client->residence,      'Empty residence';
        ok !$client->place_of_birth, 'Empty POB';

        my $res = $t->await::get_account_status({get_account_status => 1});
        test_schema('get_account_status', $res);

        # Note for this legacy scenario we strip down the country_code altogether from the response

        ok !exists($res->{get_account_status}->{authentication}->{identity}->{services}->{onfido}->{country_code}), 'Country code is not reported';
    };

    subtest 'Valid country code' => sub {
        $client->place_of_birth('br');
        $client->residence('br');
        $client->save;

        is $client->residence,      'br', 'BR residence';
        is $client->place_of_birth, 'br', 'BR POB';

        my $res = $t->await::get_account_status({get_account_status => 1});
        test_schema('get_account_status', $res);

        is $res->{get_account_status}->{authentication}->{identity}->{services}->{onfido}->{country_code}, 'BRA', 'Expected country code found';
    };
};

subtest 'POI Attempts' => sub {
    my ($vr_client, $user) = create_vr_account({
        email           => 'poi+attempts@binary.com',
        client_password => 'abc123',
        residence       => 'br',
    });

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
    $t->await::authorize({authorize => $token});

    $user->add_client($client);

    my $res = $t->await::get_account_status({get_account_status => 1});
    test_schema('get_account_status', $res);
    cmp_deeply $res->{get_account_status}->{authentication}->{attempts}, {
        count   => 0,
        history => [],
        latest  => undef,
    }, 'expected result for empty history';

    # TODO: Add more test cases when IDV is implemented
    
};

sub create_vr_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                residence       => $args->{residence},
            },
            email_verified => 1
        });

    return ($acc->{client}, $acc->{user});
}

$t->finish_ok;

done_testing;
