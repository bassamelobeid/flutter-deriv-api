use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use BOM::User::Client;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $mocked_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
my $uploaded;

$mocked_documents->mock(
    'uploaded',
    sub {
        my $self = shift;
        $self->_clear_uploaded;
        return $uploaded;
    });


subtest 'get_poi_status' => sub {
    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    my ($onfido_document_status, $onfido_sub_result);
    $mocked_onfido->mock(
        'get_latest_check',
        sub {
            return {
                report_document_status     => $onfido_document_status,
                report_document_sub_result => $onfido_sub_result,
            };
        });

    subtest 'Regulated account' => sub {
        my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my $user = BOM::User->create(
            email          => 'emailtest4@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_mf);
        $test_client_mf->status->clear_age_verification;
        undef $onfido_document_status;
        undef $onfido_sub_result;

        my $mocked_client = Test::MockModule->new(ref($test_client_mf));
        subtest 'POI status none' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => {},
                }};

            is $test_client_mf->get_poi_status, 'none', 'Client POI status is none';
            $mocked_client->unmock_all;
        };

        subtest 'POI status expired' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    documents  => {},
                }};

            is $test_client_mf->get_poi_status, 'expired', 'Client POI status is expired';
            $mocked_client->unmock_all;
        };

        subtest 'POI status pending' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $mocked_client->mock('latest_poi_by',       sub { return 'onfido' });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => {},
                }};

            $onfido_document_status = 'awaiting_applicant';
            is $test_client_mf->get_poi_status, 'pending', 'Client POI status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POI status rejected' => sub {
            $onfido_document_status = 'complete';
            $onfido_sub_result      = 'rejected';
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $mocked_client->mock('latest_poi_by',       sub { return 'onfido' });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => {},
                }};

            is $test_client_mf->get_poi_status, 'rejected', 'Client POI status is rejected';
            $mocked_client->unmock_all;
            $onfido_document_status = undef;
            $onfido_sub_result      = undef;
        };

        subtest 'POI status suspected' => sub {
            $onfido_document_status = 'complete';
            $onfido_sub_result      = 'suspected';
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $mocked_client->mock('latest_poi_by',       sub { return 'onfido' });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => {},
                }};

            is $test_client_mf->get_poi_status, 'suspected', 'Client POI status is suspected';
            $mocked_client->unmock_all;
            $onfido_document_status = undef;
            $onfido_sub_result      = undef;
        };

        subtest 'POI status verified' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 1 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => {},
                }};

            is $test_client_mf->get_poi_status, 'verified', 'Client POI status is verified';
            $mocked_client->unmock_all;
        };
    };

    $mocked_onfido->unmock_all;
};

done_testing();
