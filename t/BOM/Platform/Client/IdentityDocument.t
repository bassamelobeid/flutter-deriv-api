use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::User::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

my $cr_client  = create_client('CR',  undef, {binary_user_id => 1});
my $mx_client  = create_client('MX',  undef, {binary_user_id => 2});
my $mlt_client = create_client('MLT', undef, {binary_user_id => 3});

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
                document_type              => "passport",
                document_format            => "PDF",
                document_path              => '/tmp/test.pdf',
                expiration_date            => Date::Utility->new()->plus_time_interval('1d')->date,
                authentication_method_code => 'ID_DOCUMENT',
                checksum                   => '120EA8A25E5D487BF68B5F7096440019'
            });
            ok $client->has_valid_documents, "Client has valid documents";

            $doc->status('uploading');
            $client->save;
            ok !$client->has_valid_documents, "Documents with status of 'uploading' are not valid";

            $doc->status('uploaded');
            $client->save;
            ok $client->has_valid_documents, "Documents with status of 'uploaded' are valid";

            $doc->expiration_date('2008-03-03');    #this day should never come again.
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
my %clients_2 = (
    CR  => $CR_SIBLINGS_2,
    MX  => $MX_SIBLINGS_2,
    MLT => $MLT_SIBLINGS_2,
);

# expire the first client in the group
foreach my $broker_code (keys %clients_2) {
    # expire first client
    my $client = $clients_2{$broker_code}[0];
    my ($doc) = $client->add_client_authentication_document({
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
    foreach my $broker (keys %clients_2) {
        subtest "$broker client" => sub {
            foreach my $client ($clients_2{$broker}->@*) {
                ok $client->documents_expired, "Documents Expired";
            }
        };
    }
};

done_testing();

