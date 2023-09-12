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

subtest 'MF + CR idv test' => sub {
    my $user = BOM::User->create(
        email    => 'example+mfcf@binary.com',
        password => 'test_passwd'
    );

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id,
        residence      => 'za',
    });
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        binary_user_id => $user->id,
        residence      => 'za',
    });

    $user->add_client($client_cr);
    $user->add_client($client_mf);

    $client_cr->status->setnx('allow_document_upload');
    $client_mf->status->setnx('allow_document_upload');

    my $params = {
        token    => $token_model->create_token($client_mf->loginid, 'test token'),
        language => 'EN',
        args     => {
            issuing_country => 'ng',
            document_type   => 'nin_slip',
            document_number => '12345678912',
        },
    };

    note 'IDV for MF is not available';
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('IdentityVerificationDisallowed', 'client not allowed to upload data');

    $params->{token} = $token_model->create_token($client_cr->loginid, 'test token');

    note 'IDV for CR is working fine';
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;
};

subtest 'add document with additional field' => sub {
    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions    = {};

    $mock_emitter->mock(
        emit => sub {
            my ($event, $args) = @_;

            $emissions->{$event} = $args;

            return undef;
        });

    my $user = BOM::User->create(
        email    => 'additional.example@binary.com',
        password => 'test_passwd'
    );

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id
    });

    $user->add_client($client_cr);

    my $token_model = BOM::Platform::Token::API->new;
    my $token_cr    = $token_model->create_token($client_cr->loginid, 'test token');
    $client_cr->status->upsert('allow_document_upload', 'system', 'CRYPTO_TO_FIAT_TRANSFER_OVERLIMIT');

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client_cr->binary_user_id);

    my $params = {
        token    => $token_cr,
        language => 'EN',
    };

    $params->{args} = {
        issuing_country => 'in',
        document_type   => 'passport',
        document_number => '12345678',
    };

    $emissions = {};
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidDocumentAdditional', 'Invalid document number.');
    cmp_deeply $emissions, {}, 'No emissions were made';

    $params->{args} = {
        issuing_country => 'in',
        document_type   => 'passport',
        document_number => '12345678',
        additional      => '0'
    };

    $emissions = {};
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidDocumentAdditional', 'Invalid document number.');
    cmp_deeply $emissions, {}, 'No emissions were made';

    $params->{args} = {
        issuing_country     => 'in',
        document_type       => 'passport',
        document_number     => '12345678',
        document_additional => '123456789ABCDEF'
    };

    $emissions = {};
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error->result;

    cmp_deeply $emissions,
        {
        identity_verification_requested => {
            loginid => $client_cr->loginid,
        }
        },
        'Emission made to the IDV requested handler';

    my $document = $idv_model->get_standby_document();
    is $document->{document_number},     $params->{args}->{document_number},     'document number submitted correctly';
    is $document->{document_type},       $params->{args}->{document_type},       'document type submitted correctly';
    is $document->{issuing_country},     $params->{args}->{issuing_country},     'document issuing country submitted correctly';
    is $document->{document_additional}, $params->{args}->{document_additional}, 'document additional submitted correctly';

    $mock_emitter->unmock_all;
};

subtest 'additional field is updated' => sub {

    my $document_additional     = 'additional';
    my $new_document_additional = 'newadditional';

    my $user = BOM::User->create(
        email    => 'additional.update@binary.com',
        password => 'test123'
    );

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id
    });

    $user->add_client($client_cr);

    my $token_model = BOM::Platform::Token::API->new;
    my $token_cr    = $token_model->create_token($client_cr->loginid, 'test token');

    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions    = {};

    $mock_emitter->mock(
        emit => sub {
            my ($event, $args) = @_;

            $emissions->{$event} = $args;

            return undef;
        });

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client_cr->binary_user_id);

    my $params = {
        token    => $token_cr,
        language => 'EN',
    };

    $params->{args} = {
        issuing_country     => 'ug',
        document_type       => 'national_id_no_photo',
        document_number     => '12345678901234',
        document_additional => $document_additional
    };

    $emissions = {};
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error->result;

    cmp_deeply $emissions,
        {
        identity_verification_requested => {
            loginid => $client_cr->loginid,
        }
        },
        'Emission made to the IDV requested handler';

    my $document = $idv_model->get_standby_document();

    is $document->{document_number},     $params->{args}->{document_number}, 'document number submitted correctly';
    is $document->{document_type},       $params->{args}->{document_type},   'document type submitted correctly';
    is $document->{issuing_country},     $params->{args}->{issuing_country}, 'document issuing country submitted correctly';
    is $document->{document_additional}, $document_additional,               'document additional submitted correctly';

    $idv_model->update_document_check({
        document_id => $document->{id},
        status      => 'failed',
        messages    => [],
        provider    => 'smile_identity'
    });

    $idv_model->remove_lock;

    $params->{args}->{document_additional} = $new_document_additional;

    $emissions = {};
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error->result;

    cmp_deeply $emissions,
        {
        identity_verification_requested => {
            loginid => $client_cr->loginid,
        }
        },
        'Emission made to the IDV requested handler';

    $document = $idv_model->get_standby_document();

    is $document->{document_number},     $params->{args}->{document_number}, 'document number submitted correctly';
    is $document->{document_type},       $params->{args}->{document_type},   'document type submitted correctly';
    is $document->{issuing_country},     $params->{args}->{issuing_country}, 'document issuing country submitted correctly';
    is $document->{document_additional}, $new_document_additional,           'document additional updated correctly';

    $mock_emitter->unmock_all;
};

subtest 'underage blocked' => sub {
    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions    = {};

    $mock_emitter->mock(
        emit => sub {
            my ($event, $args) = @_;

            $emissions->{$event} = $args;

            return undef;
        });

    my $is_underage_blocked;
    my $mock_idv_model = Test::MockModule->new('BOM::User::IdentityVerification');
    $mock_idv_model->mock(
        'is_underage_blocked',
        sub {
            return $is_underage_blocked;
        });
    my $user = BOM::User->create(
        email    => 'underageblocked@binary.com',
        password => 'test_passwd'
    );

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id
    });

    $user->add_client($client_cr);

    my $token_model = BOM::Platform::Token::API->new;
    my $token_cr    = $token_model->create_token($client_cr->loginid, 'test token');

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client_cr->binary_user_id);

    my $params = {
        token    => $token_cr,
        language => 'EN',
    };

    $params->{args} = {
        issuing_country     => 'in',
        document_type       => 'passport',
        document_number     => '12345670',
        document_additional => '123456789ABCDEF'
    };

    $emissions           = {};
    $is_underage_blocked = 1;
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('UnderageBlocked', 'The document has been underage blocked.');

    cmp_deeply $emissions,
        {
        underage_client_detected => {
            from_loginid => BOM::User->new(id => 1)->get_default_client->loginid,
            loginid      => $client_cr->loginid,
            provider     => 'idv',
        }
        },
        'Expected emissions to the underage detector event';

    $emissions           = {};
    $is_underage_blocked = -1;
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('UnderageBlocked', 'The document has been underage blocked.');

    cmp_deeply $emissions,
        {
        underage_client_detected => {
            loginid  => $client_cr->loginid,
            provider => 'idv',
        }
        },
        'Expected emissions to the underage detector event';

    $emissions           = {};
    $is_underage_blocked = 0;
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $emissions,
        {
        identity_verification_requested => {
            loginid => $client_cr->loginid,
        }
        },
        'Emission made to the IDV requested handler';

    my $document = $idv_model->get_standby_document();
    is $document->{document_number},     $params->{args}->{document_number},     'document number submitted correctly';
    is $document->{document_type},       $params->{args}->{document_type},       'document type submitted correctly';
    is $document->{issuing_country},     $params->{args}->{issuing_country},     'document issuing country submitted correctly';
    is $document->{document_additional}, $params->{args}->{document_additional}, 'document additional submitted correctly';

    $mock_emitter->unmock_all;
};

subtest 'idv opt out' => sub {
    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions    = {};

    $mock_emitter->mock(
        emit => sub {
            my ($event, $args) = @_;

            $emissions->{$event} = $args;

            return undef;
        });

    my $user = BOM::User->create(
        email    => 'idv_opt_out@binary.com',
        password => 'test_passwd'
    );

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id
    });

    $user->add_client($client_cr);

    my $token_model = BOM::Platform::Token::API->new;
    my $token_cr    = $token_model->create_token($client_cr->loginid, 'test token');

    my $params = {
        token    => $token_cr,
        language => 'EN',
    };

    $params->{args} = {
        issuing_country => 'ke',
        document_type   => 'none',
        document_number => 'none'
    };

    $emissions = {};
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $emissions, {}, 'No emissions were made';

    $mock_emitter->unmock_all;
};

subtest 'on_qa_identity_verification' => sub {
    my $mock_idv_model = Test::MockModule->new('BOM::User::IdentityVerification');
    my $mock_emitter   = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $mock_qa        = Test::MockModule->new('BOM::Config');

    my @raised_events = ();
    $mock_emitter->mock(
        emit => sub {
            push @raised_events, shift;
        });

    $mock_idv_model->mock('submissions_left' => 3);
    $client_cr->status->clear_age_verification();

    my $params = {
        token    => $token_cr,
        language => 'EN',
        args     => {
            issuing_country => 'qq',
            document_type   => 'drivers_license',
            document_number => 'ABC000000000',
        }};

    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);

    $mock_qa->mock('on_qa' => 1);

    $idv_model->remove_lock;
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;

    is_deeply \@raised_events, ['identity_verification_requested'], 'the raised event is correct';

    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);

    @raised_events = ();

    $mock_idv_model->mock(
        'get_claimed_documents',
        [{
                status => 'verified',
            },
            {
                status => 'failed',
            },
            {status => 'rejected'}]);

    $idv_model->remove_lock;
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;

    is_deeply \@raised_events, ['identity_verification_requested'], 'the raised event is correct';

    @raised_events = ();

    $mock_idv_model->mock(
        'get_claimed_documents',
        [{
                status => 'failed',
            },
            {
                status => 'failed',
            },
            {status => 'pending'}]);

    $idv_model->remove_lock;
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;

    is_deeply \@raised_events, ['identity_verification_requested'], 'the raised event is correct';

    @raised_events = ();

    $params->{args} = {
        issuing_country => 'qq',
        document_type   => 'xxx',
        document_number => 'ABC000000000',
    };

    $idv_model->remove_lock;
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;

    is_deeply \@raised_events, ['identity_verification_requested'], 'the raised event is correct';

    @raised_events = ();

    $params->{args} = {
        issuing_country => 'qq',
        document_type   => 'drivers_license',
        document_number => 'WRONG NUMBER',
    };

    $idv_model->remove_lock;
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;

    is_deeply \@raised_events, ['identity_verification_requested'], 'the raised event is correct';

    @raised_events = ();

    $params->{args} = {
        issuing_country     => 'in',
        document_type       => 'passport',
        document_number     => '12345679',
        document_additional => '123456789ABCDEF'
    };

    $mock_idv_model->mock(
        'get_claimed_documents',
        [{
                status => 'failed',
            },
            {
                status => 'failed',
            },
            {status => 'rejected'}]);

    $idv_model->remove_lock;
    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error;

    is_deeply \@raised_events, ['identity_verification_requested'], 'the raised event is correct';

    $mock_qa->mock('on_qa' => 0);

    @raised_events = ();

    $params->{args} = {
        issuing_country => 'qq',
        document_type   => 'drivers_license',
        document_number => 'ABC000000000',
    };

    $idv_model->remove_lock;
    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('NotSupportedCountry', 'country "qq" does not exist outside qa env');

    is_deeply \@raised_events, [], 'the event was not raised as expected';

    $mock_idv_model->unmock_all();
    $mock_qa->unmock_all();
    $mock_emitter->unmock_all;

};

done_testing();
