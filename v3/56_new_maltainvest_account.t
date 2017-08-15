use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use BOM::Database::Model::OAuth;
use BOM::Platform::Account::Virtual;

use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;

use await;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('Client::Account');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_wsapi_test();

my %client_details = (
    new_account_real          => 1,
    salutation                => 'Ms',
    last_name                 => 'last-name',
    first_name                => 'first\'name',
    date_of_birth             => '1990-12-30',
    residence                 => 'nl',
    place_of_birth            => 'de',
    address_line_1            => 'Jalan Usahawan',
    address_line_2            => 'Enterpreneur Center',
    address_city              => 'Cyberjaya',
    address_state             => 'Selangor',
    address_postcode          => '47120',
    phone                     => '+603 34567890',
    secret_question           => 'Favourite dish',
    secret_answer             => 'nasi lemak,teh tarik',
    tax_residence             => 'de,nl',
    tax_identification_number => '111-222-333',
    account_opening_reason    => 'Speculative',
);

my $mf_details = {
    new_account_maltainvest => 1,
    accept_risk             => 1,
    account_opening_reason  => 'Speculative',
    address_line_1          => 'Test',
    %{BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash()}};

subtest 'MLT upgrade to MF account' => sub {
    # create VR acc, authorize
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+nl@binary.com',
        client_password => 'abc123',
        residence       => 'nl',
    });

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    my $mlt_loginid;
    subtest 'create MLT account, authorize' => sub {
        my $res = $t->await::new_account_real(\%client_details);
        ok($res->{new_account_real});
        test_schema('new_account_real', $res);

        $mlt_loginid = $res->{new_account_real}->{client_id};
        like($mlt_loginid, qr/^MLT\d+$/, "got MLT client $mlt_loginid");

        ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mlt_loginid);
        $t->await::authorize({authorize => $token});

        my $mlt_client = Client::Account->new({loginid => $mlt_loginid});
        is($mlt_client->financial_assessment, undef, 'doesn\'t have financial assessment');

        $res = $t->await::get_settings({get_settings => 1});
        ok($res->{get_settings});
        is($res->{get_settings}->{address_line_1}, 'Jalan Usahawan', 'address line 1 set as expexted');
    };

    subtest 'upgrade to MF' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        note explain %details;
        my $res = $t->await::new_account_maltainvest(\%details);
        ok($res->{new_account_maltainvest});
        test_schema('new_account_maltainvest', $res);

        my $loginid = $res->{new_account_maltainvest}->{client_id};
        like($loginid, qr/^MF\d+$/, "got MF client $loginid");

        my $client = Client::Account->new({loginid => $loginid});
        isnt($client->financial_assessment->data, undef, 'has financial assessment');
    };

    subtest 'MLT details should be updated as per MF' => sub {
        my $mlt_client = Client::Account->new({loginid => $mlt_loginid});
        isnt($mlt_client->financial_assessment->data, undef, 'has financial assessment after MF account creation');

        my $res = $t->await::get_settings({get_settings => 1});
        ok($res->{get_settings});
        is($res->{get_settings}->{address_line_1}, 'Test', 'address line 1 has been updated after MF account creation');
    };
};

subtest 'VR upgrade to MF - Germany' => sub {
    # create VR acc, authorize
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+de@binary.com',
        client_password => 'abc123',
        residence       => 'de',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'upgrade to MF' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{first_name} = 'first name DE';
        $details{residence}  = 'de';

        my $res = $t->await::new_account_maltainvest(\%details);
        ok($res->{new_account_maltainvest});
        test_schema('new_account_maltainvest', $res);

        my $loginid = $res->{new_account_maltainvest}->{client_id};
        like($loginid, qr/^MF\d+$/, "got MF client $loginid");

        my $client = Client::Account->new({loginid => $loginid});
        isnt($client->financial_assessment->data, undef, 'has financial assessment');

        is($client->place_of_birth, 'de',    'correct place of birth');
        is($client->tax_residence,  'de,nl', 'correct tax residence');
    };
};

subtest 'CR / MX client cannot upgrade to MF' => sub {
    my %broker_map = (
        'CR' => {
            residence  => 'id',
            email      => 'test+id@binary.com',
            first_name => 'first name ID',
        },
        'MX' => {
            residence  => 'gb',
            email      => 'test+gb@binary.com',
            first_name => 'first name GB',
        },
    );

    foreach my $broker (keys %broker_map) {
        my $map = $broker_map{$broker};
        # create VR acc, authorize
        my ($vr_client, $user) = create_vr_account({
            email           => $map->{email},
            residence       => $map->{residence},
            client_password => 'abc123',
        });
        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});

        subtest 'create MX / CR acc, authorize' => sub {
            my %details = %client_details;
            $details{first_name} = $map->{first_name};
            $details{residence}  = $map->{residence};

            my $res = $t->await::new_account_real(\%details);
            ok($res->{new_account_real});
            test_schema('new_account_real', $res);

            my $loginid = $res->{new_account_real}->{client_id};
            like($loginid, qr/^$broker\d+$/, "got $broker client $loginid");

            ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
            $t->await::authorize({authorize => $token});
        };

        subtest 'no MF upgrade for MX' => sub {
            my %details = (%client_details, %$mf_details);
            delete $details{new_account_real};
            my $res = $t->await::new_account_maltainvest(\%details);

            is($res->{error}->{code},           'InvalidAccount', "no MF upgrade for $broker");
            is($res->{new_account_maltainvest}, undef,            'NO account created');
        };
    }
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
