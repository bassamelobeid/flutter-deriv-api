use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::User::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

my $BINARY_USER_ID = 1;

my $CR2002  = create_client('CR',  undef, {binary_user_id => $BINARY_USER_ID});
my $MX0012  = create_client('MX',  undef, {binary_user_id => $BINARY_USER_ID});
my $MLT0012 = create_client('MLT', undef, {binary_user_id => $BINARY_USER_ID});

my %client = (
    CR  => $CR2002,
    MX  => $MX0012,
    MLT => $MLT0012,
);

$BINARY_USER_ID = 2;

my $CR3003  = create_client('CR',  undef, {binary_user_id => $BINARY_USER_ID});
my $MX0013  = create_client('MX',  undef, {binary_user_id => $BINARY_USER_ID});
my $MLT0013 = create_client('MLT', undef, {binary_user_id => $BINARY_USER_ID});

my %client_2 = (
    CR  => $CR3003,
    MX  => $MX0013,
    MLT => $MLT0013,
);

subtest 'Age Verified' => sub {
    plan tests => 3;
    foreach my $broker (qw(MX MLT CR)) {
        subtest "$broker client" => sub {
            my $client = $client{$broker};

            $client->status->set('age_verification', 'Darth Vader', 'Test Case');
            ok $client->status->age_verification, "Age verified by other sources";

            ok !$client->has_valid_documents, "Client Does not have a valid document";

            my ($doc) = $client->add_client_authentication_document({
                document_type              => "Passport",
                document_format            => "PDF",
                document_path              => '/tmp/test.pdf',
                expiration_date            => Date::Utility->new()->plus_time_interval('1d')->date,
                authentication_method_code => 'ID_DOCUMENT',
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

my $client = $client_2{'CR'};

my ($doc) = $client->add_client_authentication_document({
    document_type              => "Passport",
    document_format            => "PDF",
    document_path              => '/tmp/test.pdf',
    expiration_date            => '2008-03-03',
    authentication_method_code => 'ID_DOCUMENT',
    status                     => 'uploaded'
});

$client->save;

# If one client has documents expired, all the siblings are affected as well
subtest 'Documents expiry test' => sub {
    plan tests => 3;
    foreach my $broker (qw(MX MLT CR)) {
        subtest "$broker client" => sub {
            my $client = $client_2{$broker};

            ok $client->documents_expired, "Documents Expired";
        };
    }
};

done_testing();

