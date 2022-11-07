use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::Exception;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client;
use BOM::User;
use BOM::Config::Runtime;
use BOM::Config::Redis;

my $c = BOM::Test::RPC::QueueClient->new();

my $user = BOM::User->create(
    email    => 'example@binary.com',
    password => 'test_passwd'
);

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user->id
});

$user->add_client($client_cr);
$client_cr->binary_user_id($user->id);
$client_cr->save;

my $token_model = BOM::Platform::Token::API->new;
my $token_cr    = $token_model->create_token($client_cr->loginid, 'test token');

my $idv_model = BOM::User::IdentityVerification->new(user_id => $client_cr->binary_user_id);

subtest 'identity_verification_document_add' => sub {
    my $mock_idv_model            = Test::MockModule->new('BOM::User::IdentityVerification');
    my $mock_emitter              = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $previous_submissions_left = $idv_model->submissions_left();

    my @raised_events = ();
    $mock_emitter->mock(
        emit => sub {
            push @raised_events, shift;
        });

    my $params = {
        token    => $token_cr,
        language => 'EN',
        args     => {
            issuing_country => 'ng',
            document_type   => 'type',
            document_number => 'number',
        }};

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('NoAuthNeeded',
        'Add or upload document is not allowed because the corresponding status has not set.');

    $client_cr->status->setnx('allow_document_upload');
    $mock_idv_model->mock('submissions_left' => 0);

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('NoSubmissionLeft', 'No submission left occurred');

    $mock_idv_model->unmock('submissions_left');

    $params->{args} = {
        issuing_country => 'ng',
        document_type   => 'xxx',
        document_number => 'number',
    };
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidDocumentType', 'Document type does not exist.');

    $params->{args} = {
        issuing_country => 'ng',
        document_type   => 'drivers_license',
        document_number => 'WRONG NUMBER',
    };
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidDocumentNumber', 'Invalid document number.');

    $client_cr->status->setnx('age_verification', 'system', 'reason');

    $params->{args} = {
        issuing_country => 'ng',
        document_type   => 'drivers_license',
        document_number => 'ABC000000000',
    };
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('AlreadyAgeVerified', 'age already verified');

    $client_cr->status->clear_age_verification();

    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('IdentityVerificationDisabled', 'IDV is currently disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);

    $client_cr->status->setnx('unwelcome', 'system', 'reason');

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('IdentityVerificationDisallowed', 'client not allowed to upload data');

    $client_cr->status->clear_unwelcome;

    $client_cr->status->upsert('allow_document_upload', 'system', 'Anything else');

    my $mocked_client = Test::MockModule->new(ref $client_cr);

    $mocked_client->mock('get_onfido_status', 'expired');

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('IdentityVerificationDisallowed', 'client not allowed to upload data');

    $mocked_client->mock('get_onfido_status', 'rejected');

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('IdentityVerificationDisallowed', 'client not allowed to upload data');

    $mocked_client->unmock('get_onfido_status');

    $mocked_client->mock('get_manual_poi_status', 'expired');

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('IdentityVerificationDisallowed', 'client not allowed to upload data');

    $mocked_client->mock('get_manual_poi_status', 'rejected');

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('IdentityVerificationDisallowed', 'client not allowed to upload data');

    $mocked_client->unmock_all();

    $client_cr->status->upsert('allow_document_upload', 'system', 'CRYPTO_TO_FIAT_TRANSFER_OVERLIMIT');
    $mocked_client->mock('get_manual_poi_status', 'expired');

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('IdentityVerificationDisallowed', 'client not allowed to upload data');

    $mocked_client->mock('get_manual_poi_status', 'rejected');

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('IdentityVerificationDisallowed', 'client not allowed to upload data');

    $mocked_client->unmock_all();

    $mock_idv_model->mock(
        'get_claimed_documents',
        [{
                status => 'verified',
            },
            {
                status => 'failed',
            },
            {status => 'rejected'}]);

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('ClaimedDocument', "client is not allowed to use this document since it's already claimed");

    $mock_idv_model->mock(
        'get_claimed_documents',
        [{
                status => 'failed',
            },
            {
                status => 'failed',
            },
            {status => 'pending'}]);
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('ClaimedDocument', "client is not allowed to use this document since it's already claimed");

    $client_cr->status->upsert('allow_document_upload', 'system', 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT');
    $mock_idv_model->mock(
        'get_claimed_documents',
        [{
                status => 'failed',
            },
            {
                status => 'failed',
            },
            {status => 'rejected'}]);
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;

    $mock_idv_model->unmock_all();

    $params->{args} = {
        issuing_country => 'ke',
        document_type   => 'passport',
        document_number => 'G00000000',
    };
    $client_cr->status->upsert('allow_document_upload', 'system', 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT');
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;

    $params->{args} = {
        issuing_country => 'br',
        document_type   => 'cpf',
        document_number => '000.000.000-00',
    };
    $client_cr->status->upsert('allow_document_upload', 'system', 'Anything else');
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;

    $params->{args} = {
        issuing_country => 'gh',
        document_type   => 'drivers_license',
        document_number => 'B0000000',
    };
    $client_cr->status->upsert('allow_document_upload', 'system', 'CRYPTO_TO_CRYPTO_TRANSFER_OVERLIMIT');
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;

    is scalar @raised_events, 1, 'only once due to pending lock';
    is_deeply \@raised_events, ['identity_verification_requested'], 'the raised events are correct';

    is $idv_model->submissions_left(), $previous_submissions_left - 1, 'Expected submission used';

    @raised_events = ();

    $params->{args} = {
        issuing_country => 'zw',
        document_type   => 'national_id',
        document_number => '00000000A00',
    };
    $client_cr->status->upsert('allow_document_upload', 'system', 'CRYPTO_TO_FIAT_TRANSFER_OVERLIMIT');

    $idv_model->remove_lock;
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error->result;

    is scalar @raised_events, 1, 'one event has raised';
    is_deeply \@raised_events, ['identity_verification_requested'], 'the raised event is correct';

    is $idv_model->submissions_left(), $previous_submissions_left - 2, 'Expected submission used';

    my $document = $idv_model->get_standby_document();

    is $document->{document_number}, $params->{args}->{document_number}, 'document number submitted correctly';
    is $document->{document_type},   $params->{args}->{document_type},   'document type submitted correctly';
    is $document->{issuing_country}, $params->{args}->{issuing_country}, 'document issuing country submitted correctly';
};

subtest 'ignore submissions left when expired status' => sub {
    $client_cr->status->set('age_verification', 'test', 'test');

    my $params = {
        token    => $token_cr,
        language => 'EN',
    };

    $params->{args} = {
        issuing_country => 'br',
        document_type   => 'cpf',
        document_number => '000.000.001-00',
    };

    my $mock_client    = Test::MockModule->new('BOM::User::Client');
    my $idv_status     = 'none';
    my $expired_chance = 1;
    $mock_client->mock(
        'get_idv_status',
        sub {
            return $idv_status;
        });
    my $mock_idv_model = Test::MockModule->new('BOM::User::IdentityVerification');
    $mock_idv_model->mock('submissions_left' => 0);
    $mock_idv_model->mock(
        'has_expired_document_chance',
        sub {
            return $expired_chance;
        });

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('AlreadyAgeVerified', 'already age verified');

    $idv_status     = 'expired';
    $expired_chance = 1;

    ok $idv_model->has_expired_document_chance(), 'Expired chance not used';

    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error->result;

    my $document = $idv_model->get_standby_document();

    is $document->{document_number}, $params->{args}->{document_number}, 'document number submitted correctly';
    is $document->{document_type},   $params->{args}->{document_type},   'document type submitted correctly';
    is $document->{issuing_country}, $params->{args}->{issuing_country}, 'document issuing country submitted correctly';

    $expired_chance = 0;
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('AlreadyAgeVerified', 'No submission left occurred');

    $mock_client->unmock_all;
    $mock_idv_model->unmock_all;

    is $client_cr->get_idv_status, 'pending', 'Doc changed to pending';
    ok !$idv_model->has_expired_document_chance, 'Expired chance claimed';
};

done_testing();
