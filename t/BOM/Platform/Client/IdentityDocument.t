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

my $user_client_mf = BOM::User->create(
    email          => 'abcdef@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);

my $cr_client  = create_client('CR');
my $mx_client  = create_client('MX');
my $mlt_client = create_client('MLT');
my $mf_client  = create_client('MF');

$user_client_cr->add_client($cr_client);
$user_client_mx->add_client($mx_client);
$user_client_mlt->add_client($mlt_client);
$user_client_mf->add_client($mf_client);

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

            $client->status->setnx('age_verification', 'Darth Vader', 'Test Case');
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

            $doc->status('verified');
            $client->save;
            $client->load;

            ok $client->has_valid_documents, "Documents with status of 'verified' are valid";

            $doc->expiration_date('2008-03-03');    #this day should never come again.
            $doc->save;
            $doc->load;

            ok $client->has_valid_documents, "Documents are always valid if expiration check is not required"
                unless $client->is_document_expiry_check_required;
            ok !$client->has_valid_documents, "Documents that are expired are not valid if expiration check is required"
                if $client->is_document_expiry_check_required;
        };
    }
};

my $CR_SIBLINGS_2 =
    [create_client('CR'), create_client('CR')];
my $MX_SIBLINGS_2 =
    [create_client('MX'), create_client('MX')];
my $MLT_SIBLINGS_2 =
    [create_client('MLT'), create_client('MLT')];
my %clients_with_expired_check_mandatory = (
    MX  => $MX_SIBLINGS_2,
    MLT => $MLT_SIBLINGS_2,
);

$user_client_cr->add_client($_)  foreach @$CR_SIBLINGS_2;
$user_client_mx->add_client($_)  foreach @$MX_SIBLINGS_2;
$user_client_mlt->add_client($_) foreach @$MLT_SIBLINGS_2;

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
        status                     => 'verified',
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

subtest 'Valid document of Duplicate sibling account should validate its active siblings' => sub {
    $mf_client->status->set('duplicate_account');
    ok $mf_client->status->duplicate_account, "MF Account is set as duplicate_account";
    my $mf_client_2 = create_client('MF');
    $user_client_mf->add_client($mf_client_2);
    $mf_client_2->status->setnx('age_verification', 'Darth Vader', 'Test Case');
    ok $mf_client_2->status->age_verification, "Age verified by other sources";

    my ($doc) = $mf_client_2->add_client_authentication_document({
        file_name                  => $mf_client_2->loginid . '.passport.' . Date::Utility->new->epoch . '.pdf',
        document_type              => "passport",
        document_format            => "PDF",
        document_path              => '/tmp/test.pdf',
        expiration_date            => Date::Utility->new()->plus_time_interval('1d')->date,
        authentication_method_code => 'ID_DOCUMENT',
        checksum                   => '120EA8A25E5D487BF68B5F7096440019'
    });
    $doc->status('verified');
    $mf_client_2->save;
    $mf_client_2->load;
    ok $mf_client_2->has_valid_documents, "Documents with status of 'verified' are valid";
    $mf_client_2->status->set('duplicate_account');
    ok $mf_client_2->status->duplicate_account, "MF2 Account is set as duplicate_account";
    $mf_client->status->clear_duplicate_account;
    ok !$mf_client->status->duplicate_account, "MF Account is enabled now.";

    ok $mf_client->has_valid_documents, "Documents with status of 'verified' are valid";
    $doc->expiration_date('2010-10-10');
    $doc->save;
    $doc->load;
    ok !$mf_client->has_valid_documents, "If Duplicate account's document expires, documents are not valid anymore for sibling too.";
};

done_testing();

