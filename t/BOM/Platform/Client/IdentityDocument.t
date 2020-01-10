use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::User::Client;
use BOM::User;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

my $user_client_cr = BOM::User->create(
    email          => 'abc@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);

my $user_client_mx = BOM::User->create(
    email          => 'abcd@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);

my $user_client_mlt = BOM::User->create(
    email          => 'abcde@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);

my $cr_client  = create_client('CR');
my $mx_client  = create_client('MX');
my $mlt_client = create_client('MLT');

$user_client_cr->add_client($cr_client);
$user_client_mx->add_client($mx_client);
$user_client_mlt->add_client($mlt_client);

my %clients_1 = (
    CR  => $cr_client,
    MX  => $mx_client,
    MLT => $mlt_client,
);
subtest 'Age Verified' => sub {
    plan tests => 3;
    foreach my $broker (keys %clients_1) {
        subtest "$broker client" => sub {
            my $client = $clients_1{$broker};

            $client->status->set('age_verification', 'Darth Vader', 'Test Case');
            ok $client->status->age_verification, "Age verified by other sources";

            ok !$client->has_valid_documents, "Client Does not have a valid document";

            my ($doc) = $client->add_client_authentication_document({
                file_name                  => $client->loginid . '.passport.' . Date::Utility->new->epoch . '.pdf',
                document_type              => "passport",
                document_format            => "PDF",
                document_path              => '/tmp/test.pdf',
                expiration_date            => Date::Utility->new()->plus_time_interval('1d')->date,
                authentication_method_code => 'ID_DOCUMENT',
                checksum                   => '120EA8A25E5D487BF68B5F7096440019'
            });

            ok !$client->has_valid_documents, "Client with documents uploading are not valid";

            $doc->status('uploaded');
            $client->save;
            $client->load;

            ok $client->has_valid_documents, "Documents with status of 'uploaded' are valid";

            $doc->expiration_date('2008-03-03');    #this day should never come again.
            $doc->save;
            $doc->load;
            ok !$client->has_valid_documents, "Documents that are expired are not valid";
        };
    }
};

my $CR_SIBLINGS_2 =
    [create_client('CR', undef, {binary_user_id => 4}), create_client('CR', undef, {binary_user_id => 4})];
my $MX_SIBLINGS_2 =
    [create_client('MX', undef, {binary_user_id => 5}), create_client('MX', undef, {binary_user_id => 5})];
my $MLT_SIBLINGS_2 =
    [create_client('MLT', undef, {binary_user_id => 6}), create_client('MLT', undef, {binary_user_id => 6})];
my %clients_with_expired_check_mandatory = (
    MX  => $MX_SIBLINGS_2,
    MLT => $MLT_SIBLINGS_2,
);

$user_client_cr->add_client($_) foreach @$CR_SIBLINGS_2;
$user_client_cr->add_client($_) foreach @$MX_SIBLINGS_2;
$user_client_cr->add_client($_) foreach @$MLT_SIBLINGS_2;

my %clients_with_expired_check_not_mandatory = (
    CR => $CR_SIBLINGS_2,
);

my %all_clients = (%clients_with_expired_check_not_mandatory, %clients_with_expired_check_mandatory);

# expire the first client in the group
foreach my $broker_code (keys %all_clients) {
    # expire first client
    my $client = $all_clients{$broker_code}[0];
    my ($doc) = $client->add_client_authentication_document({
        file_name                  => $client->loginid . '.passport.' . Date::Utility->new('2008-02-03')->epoch . '.pdf',
        document_type              => "passport",
        document_format            => "PDF",
        document_path              => '/tmp/test.pdf',
        expiration_date            => '2008-03-03',
        authentication_method_code => 'ID_DOCUMENT',
        status                     => 'uploaded',
        checksum                   => 'CE114E4501D2F4E2DCEA3E17B546F339'
    });
    $client->save;
}

# if one sibling client expire, the rest of the siblings of that client should expire as well
subtest 'Documents expiry test' => sub {
    plan tests => 3;
    foreach my $broker (keys %clients_with_expired_check_mandatory) {
        subtest "$broker client" => sub {
            foreach my $client ($clients_with_expired_check_mandatory{$broker}->@*) {
                ok $client->documents_expired, "Documents Expired";
            }
        };
    }

    foreach my $broker (keys %clients_with_expired_check_not_mandatory) {
        subtest "$broker client" => sub {
            foreach my $client ($clients_with_expired_check_not_mandatory{$broker}->@*) {
                is $client->documents_expired, 0, "Documents Expiry Does Not Matter";
            }
        };
    }
};

done_testing();

