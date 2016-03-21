use strict;
use warnings;
use Test::More tests => 6;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

my $t = build_mojo_test();

my %client_details = (
    new_account_real => 1,
    salutation       => 'Ms',
    last_name        => 'last-name',
    first_name       => 'first\'name',
    date_of_birth    => '1990-12-30',
    residence        => 'au',
    address_line_1   => 'Jalan Usahawan',
    address_line_2   => 'Enterpreneur Center',
    address_city     => 'Cyberjaya',
    address_state    => 'Selangor',
    address_postcode => '47120',
    phone            => '+603 34567890',
    secret_question  => 'Favourite dish',
    secret_answer    => 'nasi lemak,teh tarik',
);

subtest 'new CR real account' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test@binary.com',
        client_password => 'abc123',
        residence       => 'au',
    });
    # authorize
    my $token = BOM::Platform::SessionCookie->new(
        loginid => $vr_client->loginid,
        email   => $vr_client->email,
    )->token;
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    subtest 'create CR account' => sub {
        $t = $t->send_ok({json => \%client_details})->message_ok;
        my $res = decode_json($t->message->[1]);
        ok($res->{new_account_real});
        test_schema('new_account_real', $res);

        my $loginid = $res->{new_account_real}->{client_id};
        like($loginid, qr/^CR\d+$/, "got CR client $loginid");
    };

    subtest 'no duplicate account - same email' => sub {
        $t = $t->send_ok({json => \%client_details})->message_ok;
        my $res = decode_json($t->message->[1]);

        is($res->{error}->{code},    'duplicate email', 'no duplicate account for CR');
        is($res->{new_account_real}, undef,             'NO account created');
    };

    subtest 'no duplicate - Name + DOB' => sub {
        my ($vr_client, $user) = create_vr_account({
            email           => 'test+test@binary.com',
            client_password => 'abc123',
            residence       => 'au',
        });
        # authorize
        my $token = BOM::Platform::SessionCookie->new(
            loginid => $vr_client->loginid,
            email   => $vr_client->email,
        )->token;
        $t = $t->send_ok({json => {authorize => $token}})->message_ok;

        # create CR acc
        $t = $t->send_ok({json => \%client_details})->message_ok;
        my $res = decode_json($t->message->[1]);

        is($res->{error}->{code}, 'duplicate name DOB', 'no duplicate account: same name + DOB');
        is($res->{new_account_real}, undef, 'NO account created');
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
    my $token = BOM::Platform::SessionCookie->new(
        loginid => $vr_client->loginid,
        email   => $vr_client->email,
    )->token;
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    # create real acc
    my %details = %client_details;
    $details{residence} = 'gb';
    $details{first_name} .= '-gb';

    subtest 'UK client - invalid postcode' => sub {
        $t = $t->send_ok({json => {%details, address_postcode => ''}})->message_ok;
        my $res = decode_json($t->message->[1]);

        is($res->{error}->{code}, 'invalid UK postcode', 'UK client must have postcode');
        is($res->{new_account_real}, undef, 'NO account created');
    };

    subtest 'new MX account' => sub {
        $t = $t->send_ok({json => \%details})->message_ok;
        my $res = decode_json($t->message->[1]);
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
    my $token = BOM::Platform::SessionCookie->new(
        loginid => $vr_client->loginid,
        email   => $vr_client->email,
    )->token;
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    # create real acc
    my %details = %client_details;
    $details{residence} = 'nl';
    $details{first_name} .= '-nl';

    $t = $t->send_ok({json => \%details})->message_ok;
    my $res = decode_json($t->message->[1]);
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
    my $token = BOM::Platform::SessionCookie->new(
        loginid => $vr_client->loginid,
        email   => $vr_client->email,
    )->token;
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    subtest 'insufficient info' => sub {
        # create real acc
        my %details = %client_details;
        delete $details{residence};
        delete $details{first_name};

        $t = $t->send_ok({json => \%details})->message_ok;
        my $res = decode_json($t->message->[1]);

        is($res->{error}->{code}, 'InputValidationFailed', 'fail input validation');
        is($res->{new_account_real}, undef, 'NO account created');
    };

    subtest 'email unverified' => sub {
        $user->email_verified(0);
        $user->save;

        # create real acc
        my %details = %client_details;
        $details{residence} = 'id';
        $details{first_name} .= '-id';

        $t = $t->send_ok({json => \%details})->message_ok;
        my $res = decode_json($t->message->[1]);

        is($res->{error}->{code}, 'email unverified', 'email unverified');
        is($res->{new_account_real}, undef, 'NO account created');
    };

    $user->email_verified(1);
    $user->save;

    subtest 'virtual no residence' => sub {
        $vr_client->residence('');
        $vr_client->save;

        # create real acc
        my %details = %client_details;
        $details{residence} = 'id';

        $t = $t->send_ok({json => \%details})->message_ok;
        my $res = decode_json($t->message->[1]);

        is($res->{error}->{code},    'InvalidAccount', 'cannot create real account');
        is($res->{new_account_real}, undef,            'NO account created');
    };

    $vr_client->residence('id');
    $vr_client->save;

    subtest 'residence unmatch with Virtual acc' => sub {
        my %details = %client_details;
        $details{residence} = 'au';

        $t = $t->send_ok({json => \%details})->message_ok;
        my $res = decode_json($t->message->[1]);

        is($res->{error}->{code}, 'invalid residence', 'cannot create real account');
        is($res->{new_account_real}, undef, 'NO account created');
    };

    subtest 'no POBox for address' => sub {
        my %details = %client_details;
        $details{residence} = 'id';

        $t = $t->send_ok({json => {%details, address_line_1 => 'address 1 P.O.Box 1234'}})->message_ok;
        my $res = decode_json($t->message->[1]);

        is($res->{error}->{code},    'invalid PO Box', 'address cannot contain P.O.Box');
        is($res->{new_account_real}, undef,            'NO account created');
    };

    subtest 'min age check' => sub {
        my %details = %client_details;
        $details{residence} = 'id';

        $t = $t->send_ok({json => {%details, date_of_birth => '2008-01-01'}})->message_ok;
        my $res = decode_json($t->message->[1]);

        is($res->{error}->{code},    'too young', 'min age unmatch');
        is($res->{new_account_real}, undef,       'NO account created');
    };

    subtest 'restricted or invalid country' => sub {
        subtest 'restricted - US' => sub {
            $vr_client->residence('us');
            $vr_client->save;

            my %details = %client_details;
            $details{residence} = 'us';

            $t = $t->send_ok({json => \%details})->message_ok;
            my $res = decode_json($t->message->[1]);

            is($res->{error}->{code},    'InvalidAccount', 'restricted country - US');
            is($res->{new_account_real}, undef,            'NO account created');
        };
        subtest 'invalid - xx' => sub {
            $vr_client->residence('xx');
            $vr_client->save;

            my %details = %client_details;
            $details{residence} = 'xx';

            $t = $t->send_ok({json => \%details})->message_ok;
            my $res = decode_json($t->message->[1]);

            is($res->{error}->{code},    'InvalidAccount', 'invalid country - xx');
            is($res->{new_account_real}, undef,            'NO account created');
        };
    };

    subtest 'no MF or JP' => sub {
        subtest 'Maltainvest' => sub {
            $vr_client->residence('de');
            $vr_client->save;

            my %details = %client_details;
            $details{residence} = 'de';

            $t = $t->send_ok({json => \%details})->message_ok;
            my $res = decode_json($t->message->[1]);

            is($res->{error}->{code},    'InvalidAccount', 'wrong acc opening - MF');
            is($res->{new_account_real}, undef,            'NO account created');
        };
        subtest 'Japan' => sub {
            $vr_client->residence('jp');
            $vr_client->save;

            my %details = %client_details;
            $details{residence} = 'jp';

            $t = $t->send_ok({json => \%details})->message_ok;
            my $res = decode_json($t->message->[1]);

            is($res->{error}->{code},    'InvalidAccount', 'wrong acc opening - JP');
            is($res->{new_account_real}, undef,            'NO account created');
        };
    };
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
