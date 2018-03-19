use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;
use BOM::User::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $CR2002  = BOM::User::Client->new({loginid => 'CR2002'});
my $MX0012  = BOM::User::Client->new({loginid => 'MX0012'});
my $MLT0012 = BOM::User::Client->new({loginid => 'MLT0012'});
my %client  = (
    CR  => $CR2002,
    MX  => $MX0012,
    MLT => $MLT0012,
);

my $CR3003  = BOM::User::Client->new({loginid => 'CR3003'});
my $MX0013  = BOM::User::Client->new({loginid => 'MX0013'});
my $MLT0013 = BOM::User::Client->new({loginid => 'MLT0013'});
my %client_2 = (
    CR  => $CR3003,
    MX  => $MX0013,
    MLT => $MLT0013,
);

subtest 'Age Verified' => sub {
    foreach my $broker (qw(MX MLT CR)) {
        subtest "$broker client" => sub {
            my $client = $client{$broker};

            $client->set_status('age_verification', 'Darth Vader', 'Test Case');
            ok $client->get_status('age_verification'), "Age verified by other sources";

            ok !$client->has_valid_documents, "Client Does not have a valid document";

            my ($doc) = $client->add_client_authentication_document({
                document_type              => "Passport",
                document_format            => "PDF",
                document_path              => '/tmp/test.pdf',
                expiration_date            => '2025-10-10',
                authentication_method_code => 'ID_DOCUMENT'
            });
            ok $client->has_valid_documents, "Client now has a valid document";

            $doc->expiration_date('2008-03-03');    #this day should never come again.
            ok !$client->has_valid_documents, "Documents are not valid any more";
        };
    }
};

subtest 'Cashier Locked' => sub {
    foreach my $broker (qw(MX MLT CR)) {
        subtest "$broker client" => sub {
            my $client = $client_2{$broker};

            ok !$client->documents_expired, "No documents so nothing to expire";
            ok !$client->get_status('cashier_locked'), "No first depost so cashier not locked";

            my ($doc) = $client->add_client_authentication_document({
                document_type              => "Passport",
                document_format            => "PDF",
                document_path              => '/tmp/test.pdf',
                expiration_date            => '2025-10-10',
                authentication_method_code => 'ID_DOCUMENT'
            });
            $client->save;

            $client->load;
            ok !$client->documents_expired, "Has documents but not expired";
            ok !$client->get_status('cashier_locked'), "Valid Documents so cashier not locked";

            $doc->expiration_date('2008-03-03');    #this day should never come again.
            ok $client->documents_expired, "Documents Expired";
        };
    }
};

