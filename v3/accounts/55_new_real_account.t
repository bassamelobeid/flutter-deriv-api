use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;

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

my %client_details = (
    new_account_real       => 1,
    salutation             => 'Ms',
    last_name              => 'last-name',
    first_name             => 'first\'name',
    date_of_birth          => '1990-12-30',
    residence              => 'au',
    place_of_birth         => 'de',
    address_line_1         => 'Jalan Usahawan',
    address_line_2         => 'Enterpreneur Center',
    address_city           => 'Cyberjaya',
    address_state          => 'Selangor',
    address_postcode       => '47120',
    phone                  => '+60321685000',
    secret_question        => 'Favourite dish',
    secret_answer          => 'nasi lemak,teh tarik',
    account_opening_reason => 'Speculative'
);

subtest 'new CR real account' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test@binary.com',
        client_password => 'abc123',
        residence       => 'au',
    });
    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'create CR account' => sub {
        my ($res, $call_params) = call_mocked_client($t, \%client_details);
        is $call_params->{token}, $token;
        ok($res->{msg_type}, 'new_account_real');
        ok($res->{new_account_real});
        test_schema('new_account_real', $res);

        my $loginid = $res->{new_account_real}->{client_id};
        like($loginid, qr/^CR\d+$/, "got CR client $loginid");
    };
};

subtest 'new MX real account' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+gb@binary.com',
        client_password => 'abc123',
        residence       => 'gb',
    });
    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    # create real acc
    my %details = %client_details;
    $details{residence} = 'gb';
    $details{citizen}   = 'gb';
    $details{first_name} = 'Valid';
    $details{phone} = '+442072343456';

    subtest 'UK client - invalid postcode' => sub {
        my $res = $t->await::new_account_real({%details, address_postcode => ''}, { timeout => 10 });

        is($res->{error}->{code}, 'InsufficientAccountDetails', 'UK client must have postcode');
        is_deeply($res->{error}->{details}, {missing => ['address_postcode']});

        is($res->{new_account_real}, undef, 'NO account created');
    };

    subtest 'new MX account' => sub {
        my $res = $t->await::new_account_real(\%details, { timeout => 10 });
        ok($res->{new_account_real});
        test_schema('new_account_real', $res);

        my $loginid = $res->{new_account_real}->{client_id};
        like($loginid, qr/^MX\d+$/, "got MX client - $loginid");
    };
};

subtest 'new MLT real account' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+nl@binary.com',
        client_password => 'abc123',
        residence       => 'nl',
    });
    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    # create real acc
    my %details = %client_details;
    $details{residence} = 'nl';
    $details{first_name} = 'first\'name';
    $details{citizen} = 'nl';
    $details{phone}   = '+31205551111';

    my $res = $t->await::new_account_real(\%details);
    ok($res->{new_account_real});
    test_schema('new_account_real', $res);

    my $loginid = $res->{new_account_real}->{client_id};
    like($loginid, qr/^MLT\d+$/, "got MLT client - $loginid");
};

subtest 'create account failed' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+id@binary.com',
        client_password => 'abc123',
        residence       => 'id',
    });
    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'email unverified' => sub {
        $user->update_email_fields(email_verified => 'f');

        # create real acc
        my %details = %client_details;
        $details{residence} = 'id';
        $details{first_name} .= '-id';
        $details{phone} = '+60321685001';

        my $res = $t->await::new_account_real(\%details);

        is($res->{error}->{code}, 'email unverified', 'email unverified');
        is($res->{new_account_real}, undef, 'NO account created');
    };

    $user->update_email_fields(email_verified => 't');

    $vr_client->residence('id');
    $vr_client->save;

    subtest 'residence unmatch with Virtual acc' => sub {
        my %details = %client_details;
        $details{residence} = 'au';

        my $res = $t->await::new_account_real(\%details);

        is($res->{error}->{code}, 'invalid residence', 'cannot create real account');
        is($res->{new_account_real}, undef, 'NO account created');
    };

    subtest 'no POBox for address' => sub {
        my %details = %client_details;
        $details{residence} = 'id';

        my $res = $t->await::new_account_real({%details, address_line_1 => 'address 1 P.O.Box 1234'});

        is($res->{error}->{code},    'invalid PO Box', 'address cannot contain P.O.Box');
        is($res->{new_account_real}, undef,            'NO account created');
    };

    subtest 'min age check' => sub {
        my %details = %client_details;
        $details{residence} = 'id';

        my $res = $t->await::new_account_real({%details, date_of_birth => '2008-01-01'});
        is($res->{error}->{code},    'too young', 'min age unmatch');
        is($res->{new_account_real}, undef,       'NO account created');
    };

    subtest 'insufficient info' => sub {
        # create real acc
        my %details = %client_details;
        delete $details{first_name};

        my $res = $t->await::new_account_real(\%details);

        is($res->{error}->{code}, 'InputValidationFailed', 'not enough info');
        is_deeply($res->{error}->{details}, {first_name => 'Missing property.'}, "error info ok");
        is($res->{new_account_real}, undef, 'NO account created');
    };

    subtest 'restricted or invalid country' => sub {
        subtest 'restricted - US' => sub {
            $vr_client->residence('us');
            $vr_client->save;

            my %details = %client_details;
            $details{residence} = 'us';

            my $res = $t->await::new_account_real(\%details);

            is($res->{error}->{code},    'InvalidAccount', 'restricted country - US');
            is($res->{new_account_real}, undef,            'NO account created');
        };

        subtest 'invalid - xx' => sub {
            $vr_client->residence('xx');
            $vr_client->save;

            my %details = %client_details;
            $details{residence} = 'xx';

            my $res = $t->await::new_account_real(\%details);

            is($res->{error}->{code},    'InvalidAccount', 'invalid country - xx');
            is($res->{new_account_real}, undef,            'NO account created');
        };
    };

    subtest 'no MF' => sub {
        $vr_client->residence('de');
        $vr_client->save;

        my %details = %client_details;
        $details{residence} = 'de';

        my $res = $t->await::new_account_real(\%details);

        is($res->{error}->{code},    'InvalidAccount', 'wrong acc opening - MF');
        is($res->{new_account_real}, undef,            'NO account created');
    };
};

subtest 'new_real_account with currency provided' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+111@binary.com',
        client_password => 'abC123',
        residence       => 'au',
    });
    my %details = %client_details;
    use Data::Dumper;

    my $compiled_checks = sub {
        my ($res, $details) = @_;
        my $loginid = $res->{new_account_real}->{client_id};

        ok($res->{msg_type}, 'new_account_real');
        ok($res->{new_account_real});
        test_schema('new_account_real', $res);
        like($loginid, qr/^CR\d+$/, "got CR client $loginid");
        is($res->{new_account_real}->{currency}, $details->{currency}, "currency set as per request");
    };

    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    $details{currency}  = 'USD';
    $details{last_name} = 'Torvalds';
    $details{phone}     = '+60321685007';
    my $res = $t->await::new_account_real(\%details);
    $compiled_checks->($res, \%details);

    # now let's login as a real account and try to create more accounts
    $token = $res->{new_account_real}->{oauth_token};
    $t->await::authorize({authorize => $token});

    $res = $t->await::new_account_real(\%details);
    is($res->{error}->{code}, 'CurrencyTypeNotAllowed', 'Second account with the same currency is not allowed');

    $details{currency} = 'LTC';
    $res = $t->await::new_account_real(\%details);
    $compiled_checks->($res, \%details);

    $details{currency} = 'ETH';
    $res = $t->await::new_account_real(\%details);
    $compiled_checks->($res, \%details);

    $details{currency} = 'XXX';
    $res = $t->await::new_account_real(\%details);
    is($res->{error}->{code}, 'CurrencyTypeNotAllowed', 'Try to create account with incorrect currency');
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
