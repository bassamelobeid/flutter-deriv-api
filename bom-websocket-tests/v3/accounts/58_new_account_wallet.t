use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;
use BOM::Config::Runtime;

use await;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_wsapi_test();

my %details = (
    new_account_wallet => 1,
    last_name          => 'last-name',
    first_name         => 'first\'name',
    date_of_birth      => '1990-12-30',
    address_line_1     => 'Tolstoy',
    address_city       => 'Moskva',
    address_state      => 'Moskva',
    address_postcode   => '47120',
    phone              => '+60321685000',
);

subtest 'new real wallet  account' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+gb@binary.com',
        client_password => 'abc123',
        residence       => 'ru',
    });
    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'new wallet account without currency' => sub {
        my $res = $t->await::new_account_wallet({%details, payment_method => 'Skrill'}, {timeout => 10});
        is($res->{error}->{code},      'InputValidationFailed', 'Currency is mandatory');
        is($res->{new_account_wallet}, undef,                   'NO account created');
    };

    subtest 'new wallet account without payment method' => sub {
        my $res = $t->await::new_account_wallet({%details, currency => 'USD'}, {timeout => 10});
        is($res->{error}->{code},      'InputValidationFailed', 'Payment method is mandatory');
        is($res->{new_account_wallet}, undef,                   'NO account created');
    };

    SKIP: {
        skip "Since wallets are not enabled for any country at the moment, it's not possible to test the successful scenario."
            if BOM::Config::Runtime->instance->app_config->system->suspend->wallets;

        subtest 'new wallet account' => sub {
            my $res = $t->await::new_account_wallet({
                    %details,
                    salutation     => 'Ms',
                    payment_method => 'Skrill',
                    currency       => 'USD'
                },
                {timeout => 10});
            ok($res->{new_account_wallet});
            test_schema('new_account_wallet', $res);
            my $loginid = $res->{new_account_wallet}->{client_id};
            like($loginid, qr/^DW\d+$/, "got DW client - $loginid");

            my $client = BOM::User::Client->new({loginid => $loginid});
            $client->address_state, 'MOW', 'State name is convered into state code';
        };

        subtest 'Personal details are optional in case real account exists' => sub {
            my $res = $t->await::new_account_wallet({
                    new_account_wallet => 1,
                    salutation         => 'Mr',
                    payment_method     => 'Zingpay',
                    currency           => 'USD'
                },
                {timeout => 10});
            ok($res->{new_account_wallet});
            test_schema('new_account_wallet', $res);
            my $loginid = $res->{new_account_wallet}->{client_id};
            like($loginid, qr/^DW\d+$/, "got DW client - $loginid");
        };
    }

    subtest 'new wallet account is disabled for all countries at the moment' => sub {
        ok(BOM::Config::Runtime->instance->app_config->system->suspend->wallets, 'wallet service is disabled at the moment');

        my $res = $t->await::new_account_wallet({
                %details,
                salutation     => 'Miss',
                currency       => 'USD',
                payment_method => 'fiat'
            },
            {timeout => 10});

        ok $res->{error}, 'error is received when wallet service is suspended.';
        is($res->{new_account_wallet}, undef, 'NO account created');
    };
};

sub create_vr_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                residence       => $args->{residence},
                account_type    => 'binary',
                email_verified  => 1,
            },
        });

    return ($acc->{client}, $acc->{user});
}

$t->finish_ok;

done_testing;
