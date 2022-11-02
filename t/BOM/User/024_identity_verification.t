use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Log::Any::Test;
use Log::Any qw($log);
use Test::Deep;
use Test::Exception;
use Test::MockObject;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User;
use BOM::User::IdentityVerification;

use JSON::MaybeUTF8 qw( decode_json_utf8 );

my $user_cr;
my $user_mf;

my $client_cr;
my $client_mf;

my $idv_model_ccr;
my $idv_model_cmf;

my $idv_model_nx;

lives_ok {
    $user_cr = BOM::User->create(
        email    => 'cr@binary.com',
        password => "hello",
    );
    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user_cr->id,
    });
    $user_cr->add_client($client_cr);

    $user_mf = BOM::User->create(
        email    => 'mf@binary.com',
        password => "hello",
    );
    $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        binary_user_id => $user_mf->id,
    });
    $user_mf->add_client($client_cr);

    $idv_model_ccr = BOM::User::IdentityVerification->new(user_id => $user_cr->id);
    $idv_model_cmf = BOM::User::IdentityVerification->new(user_id => $user_mf->id);
    $idv_model_nx  = BOM::User::IdentityVerification->new(user_id => -1);             # idv model for not existent user
}
'The initalization was successful';

isa_ok $idv_model_ccr, 'BOM::User::IdentityVerification', '$idv_model_ccr instance';
is $idv_model_ccr->user_id, $client_cr->binary_user_id, 'User id set correctly';

isa_ok $idv_model_cmf, 'BOM::User::IdentityVerification', '$idv_model_cmf instance';
is $idv_model_cmf->user_id, $client_mf->binary_user_id, 'User id set correctly';

subtest 'add document' => sub {
    lives_ok {
        $idv_model_ccr->add_document({
            issuing_country => 'ir',
            number          => '1234',
            type            => 'sejeli'
        });
    }
    'document added successfully';

    my $document = $user_cr->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM idv.document WHERE binary_user_id=?::BIGINT', undef, $client_cr->binary_user_id);
        });

    is $document->{issuing_country}, 'ir',      'issuing country persisted';
    is $document->{status},          'pending', 'status is set to pending correctly';
    is $document->{expiration_date}, undef,     'expiration date not set correctly';

    lives_ok {
        $idv_model_cmf->add_document({
            issuing_country => 'ir',
            number          => 'abcd9876',
            type            => 'melli-card',
            expiration_date => '2085-02-02'
        });
    }
    'document re-added with expiration date successfully';

    $document = $user_mf->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM idv.document WHERE binary_user_id=?::BIGINT', undef, $client_mf->binary_user_id);
        });

    is $document->{document_type},            'melli-card',          'document type is correct';
    is $document->{issuing_country},          'ir',                  'issuing country is changed';
    is $document->{status},                   'pending',             'status is pending correctly';
    is $document->{document_expiration_date}, '2085-02-02 00:00:00', 'expiration date set correctly';

    throws_ok {
        local $SIG{__WARN__} = undef;
        $idv_model_nx->add_document({
            issuing_country => 'ir',
            number          => '1234',
            type            => 'sejeli'
        });
    }
    qr/is not present in table "binary_user"/, 'add document failed due to not existent user';

    throws_ok {
        local $SIG{__WARN__} = undef;
        $idv_model_ccr->add_document();
    }
    qr/issuing_country/, 'missing issuing country';

    throws_ok {
        local $SIG{__WARN__} = undef;
        $idv_model_ccr->add_document({issuing_country => 'ir'});
    }
    qr/number/, 'missing document number';

    throws_ok {
        local $SIG{__WARN__} = undef;
        $idv_model_ccr->add_document({
            issuing_country => 'ir',
            number          => '1234'
        });
    }
    qr/type/, 'missing document type';

};

subtest 'get standby document' => sub {
    my $document;

    lives_ok {
        $idv_model_ccr->add_document({
            issuing_country => 'ke',
            number          => '1234',
            type            => 'national_id'
        });
    }
    'document added successfully';

    lives_ok {
        $document = $idv_model_ccr->get_standby_document();
    }
    'standby document fetched';

    is $document->{issuing_country}, 'ke',          'issuing country is correct';
    is $document->{document_type},   'national_id', 'type is correct';

    lives_ok {
        $idv_model_ccr->add_document({
            issuing_country => 'br',
            number          => 'matata',
            type            => 'driver_licence',
            expiration_date => '2099-01-01'
        });
    }
    'document added successfully';

    lives_ok {
        $document = $idv_model_ccr->get_standby_document();
    }
    'standby document fetched since it\'s not reached expiration date yet';

    is $document->{issuing_country}, 'br',             'issuing country is correct';
    is $document->{document_type},   'driver_licence', 'driver_licence is correct';

    lives_ok {
        $idv_model_ccr->add_document({
            issuing_country => 'br',
            number          => 'matata',
            type            => 'driver_licence',
            expiration_date => '1999-01-01'
        });
    }
    'document added successfully';

    lives_ok {
        $document = $idv_model_cmf->get_standby_document();
    }
    'standby document fetched the last not expired document';

    is $document->{issuing_country}, 'ir',         'issuing country is correct';
    is $document->{document_type},   'melli-card', 'melli-card is correct';

    lives_ok {
        $document = $idv_model_nx->get_standby_document();
    }
    'no document fetched';

    ok !$document, 'no document found';
};

subtest 'update document check' => sub {
    my $document;

    lives_ok {
        $document = $idv_model_ccr->add_document({
            issuing_country => 'ng',
            number          => '74747',
            type            => 'id',
            expiration_date => '2099-01-01'
        });
    }
    'document added successfully';

    lives_ok {
        $document = $idv_model_ccr->get_last_updated_document();
    }
    'last updated document fetched';

    is $document->{status},                   'pending',             'status is correct';
    is $document->{issuing_country},          'ng',                  'issuing country is correct';
    is $document->{document_expiration_date}, '2099-01-01 00:00:00', 'expiration date is correct';
    is $document->{is_checked},               0,                     'check detailes is not there';

    lives_ok {
        $idv_model_ccr->update_document_check({
            document_id => $document->{id},
            status      => 'verified',
            messages    => ['got', undef, 'cha'],
            provider    => 'smile_identity'
        });
    }
    'document updated sucessfully';

    lives_ok {
        $document = $idv_model_ccr->get_last_updated_document();
    }
    'last updated document fetched';

    is $document->{status},                   'verified',            'status is correct';
    is $document->{issuing_country},          'ng',                  'issuing country is correct';
    is $document->{document_expiration_date}, '2099-01-01 00:00:00', 'expiration date is correct';
    is $document->{is_checked},               1,                     'check detailes added is correct';
    cmp_deeply decode_json_utf8($document->{status_messages}), ['got', undef, 'cha'], 'expected status messages';

    my $document_id = $document->{id};
    $log->contains_ok(qr/IdentityVerification is pushing a NULL status message, document_id=$document_id, provider=smile_identity/,
        'Expected warning logged');

    throws_ok {
        local $SIG{__WARN__} = undef;
        $idv_model_nx->update_document_check({document_id => -1});
    }
    qr/The document you are looking for is not there/, 'update failed due to not existent document';

    throws_ok {
        local $SIG{__WARN__} = undef;
        $idv_model_ccr->update_document_check();
    }
    qr/document_id/, 'missing document_id';

    throws_ok {
        local $SIG{__WARN__} = undef;
        $idv_model_ccr->update_document_check({
            document_id => $document->{id},
            provider    => 'not exists provider'
        });
    }
    qr/invalid input value for enum idv.provider/, 'invalid provider';

    throws_ok {
        local $SIG{__WARN__} = undef;
        $idv_model_ccr->update_document_check({
            document_id => $document->{id},
            status      => 'not exists status'
        });
    }
    qr/invalid input value for enum idv.check_status/, 'invalid check status';
};

subtest 'get_last_updated_document' => sub {
    my $document;

    my $ng_doc_id;

    lives_ok {
        $document = $idv_model_ccr->add_document({
            issuing_country => 'ng',
            number          => '74747',
            type            => 'id',
            expiration_date => '2099-01-01'
        });
        $ng_doc_id = $document->{id};
    }
    'document added successfully';

    lives_ok {
        $document = $idv_model_ccr->get_last_updated_document();
    }
    'last updated document fetched';

    is $document->{status},                   'pending',             'status is correct';
    is $document->{issuing_country},          'ng',                  'issuing country is correct';
    is $document->{document_expiration_date}, '2099-01-01 00:00:00', 'expiration date is correct';
    is $document->{is_checked},               1,                     'check detailes added is correct';

    lives_ok {
        $idv_model_ccr->add_document({
            issuing_country => 'ke',
            number          => '1234',
            type            => 'national',
            expiration_date => '2099-01-01'
        });
    }
    'document added successfully';

    lives_ok {
        $document = $idv_model_ccr->get_last_updated_document();
    }
    'last updated document fetched';

    is $document->{status},                   'pending',             'status is correct';
    is $document->{issuing_country},          'ke',                  'issuing country is correct';
    is $document->{document_expiration_date}, '2099-01-01 00:00:00', 'expiration date is correct';
    is $document->{is_checked},               0,                     'check detailes added is correct';

    lives_ok {
        $idv_model_ccr->update_document_check({
            document_id => $ng_doc_id,
            status      => 'verified',
            messages    => ['gotcha'],
            provider    => 'smile_identity'
        });
    }
    'document updated sucessfully';

    lives_ok {
        $document = $idv_model_ccr->get_last_updated_document();
    }
    'last updated document fetched';

    is $document->{status},                   'verified',            'status is correct';
    is $document->{issuing_country},          'ng',                  'issuing country is correct';
    is $document->{document_expiration_date}, '2099-01-01 00:00:00', 'expiration date is correct';
    is $document->{is_checked},               1,                     'check detailes added is correct';
};

subtest 'get document check detail' => sub {
    my $document;
    my $check;

    lives_ok {
        $document = $idv_model_ccr->add_document({
            issuing_country => 'xx',
            number          => '6666',
            type            => 'license',
            expiration_date => '2099-01-01'
        });
    }
    'document added successfully';

    lives_ok {
        $document = $idv_model_ccr->get_last_updated_document();
    }
    'last updated document fetched';

    is $document->{is_checked}, 0, 'check detailes is not there';

    lives_ok {
        $idv_model_ccr->update_document_check({
            document_id  => $document->{id},
            status       => 'verified',
            messages     => ['gotcha'],
            provider     => 'smile_identity',
            request_body => '{}'
        });
    }
    'document updated sucessfully';

    lives_ok {
        $document = $idv_model_ccr->get_last_updated_document();
    }
    'last updated document fetched';

    is $document->{is_checked}, 1, 'check detailes added is correct';

    lives_ok {
        $check = $idv_model_ccr->get_document_check_detail($document->{id});
    }
    'check details fetched';

    is $check->{provider}, 'smile_identity', 'provider is correct';
    is $check->{request},  '{}',             'request is correct';

    throws_ok {
        local $SIG{__WARN__} = undef;
        $idv_model_ccr->get_document_check_detail();
    }
    qr/document_id/, 'missing document_id';
};

subtest 'get claimed documents' => sub {
    my ($document1, $document2, $claims);

    lives_ok {
        $document1 = $idv_model_ccr->add_document({
            issuing_country => 'ir',
            number          => '125',
            type            => 'nin',
            expiration_date => '2099-01-01'
        });
    }
    'document added successfully';

    lives_ok {
        $document2 = $idv_model_cmf->add_document({
            issuing_country => 'ir',
            number          => '125',
            type            => 'nin',
            expiration_date => '2099-01-01'
        });
    }
    'document added successfully';

    lives_ok {
        $claims = $idv_model_nx->get_claimed_documents({
            issuing_country => 'ir',
            number          => '125',
            type            => 'nin'
        });
    }
    'claimed docs details fetched';

    is scalar @$claims, 2, 'fetched claimed docs number is correct';

    throws_ok {
        local $SIG{__WARN__} = undef;
        $idv_model_ccr->get_claimed_documents();
    }
    qr/issuing_country/, 'missing issuing_country';
};

subtest 'Submissions Left' => sub {
    is $idv_model_ccr->submissions_left($client_mf), 3, 'Expected submissions left';
};

subtest 'Limit per user' => sub {
    is $idv_model_ccr->limit_per_user($client_cr), 3, 'Expected limit per user';
};

subtest 'Incr submissions' => sub {
    $idv_model_ccr->incr_submissions;
    is $idv_model_ccr->submissions_left, 2, 'Expected submissions left';

    $idv_model_ccr->incr_submissions;
    is $idv_model_ccr->submissions_left, 1, 'Expected submissions left';

    $idv_model_ccr->incr_submissions;
    is $idv_model_ccr->submissions_left, 0, 'Expected submissions left';

    $idv_model_ccr->incr_submissions;
    is $idv_model_ccr->submissions_left, 0, 'Expected submissions left (does not cross the limit)';

    subtest 'reset attempts' => sub {
        $idv_model_ccr->reset_attempts();
        is $idv_model_ccr->submissions_left, 3, 'The attempts of the client have come back';
    };
};

subtest 'Decr submissions' => sub {
    $idv_model_ccr->decr_submissions;
    is $idv_model_ccr->submissions_left, 4, 'Expected submissions left';
};

subtest 'Reset submissions to zero' => sub {
    is $idv_model_ccr->submissions_left, 4, 'Expected submissions left is correct';
    BOM::User::IdentityVerification::reset_to_zero_left_submissions($user_cr->id);
    is $idv_model_ccr->submissions_left, 0, 'Expected submissions left is reset';
};

subtest 'Expired docs chance' => sub {
    ok $idv_model_ccr->has_expired_document_chance(), 'Has the chance';
    ok $idv_model_ccr->has_expired_document_chance(), 'Has the chance';
    is $idv_model_ccr->expired_document_chance_ttl(), -2, 'key does not exist';
    ok $idv_model_ccr->claim_expired_document_chance(),   'chance claimed';
    ok !$idv_model_ccr->has_expired_document_chance(),    'Expired chance not available yet';
    ok $idv_model_ccr->expired_document_chance_ttl() > 0, 'ttl set';
    $idv_model_ccr->reset_attempts();
    ok $idv_model_ccr->has_expired_document_chance(), 'Expired chance is available again';
};

subtest 'is idv disallowed' => sub {
    my $user_cr = BOM::User->create(
        email    => 'cr+idv+disalloed@binary.com',
        password => "hello",
    );
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user_cr->id,
    });
    $user_cr->add_client($client_cr);

    my $mocked_lc = Test::MockModule->new(ref($client_cr->landing_company));
    my $short;

    $mocked_lc->mock(
        'short',
        sub {
            return $short;
        });

    my $mocked_cli = Test::MockModule->new(ref($client_cr));
    my $manual_status;
    my $onfido_status;

    $mocked_cli->mock(
        'get_manual_poi_status',
        sub {
            return $manual_status;
        });

    $mocked_cli->mock(
        'get_onfido_status',
        sub {
            return $onfido_status;
        });

    $short = 'bvi';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client_cr), 'Only svg is allowed to use IDV';

    $client_cr->status->set('unwelcome', 'test', 'test');

    $short = 'svg';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client_cr), 'Disallowed for unwelcome clients';

    $client_cr->status->clear_unwelcome();

    $client_cr->status->_build_all();

    $client_cr->aml_risk_classification('high');

    ok BOM::User::IdentityVerification::is_idv_disallowed($client_cr), 'Disallowed for AML high risk clients';

    $client_cr->aml_risk_classification('low');

    $client_cr->status->set('age_verification', 'test', 'test');

    ok BOM::User::IdentityVerification::is_idv_disallowed($client_cr), 'Disallowed for age verified clients';

    $client_cr->status->clear_age_verification();

    $client_cr->status->set('allow_poi_resubmission', 'test', 'test');

    $client_cr->status->_build_all();

    ok BOM::User::IdentityVerification::is_idv_disallowed($client_cr), 'Disallowed for poi resubmissions';

    $client_cr->status->clear_allow_poi_resubmission();

    $client_cr->status->set('allow_document_upload', 'test', 'test');

    $client_cr->status->_build_all();

    $manual_status = 'expired';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client_cr), 'Disallowed for manual poi status expired';

    $manual_status = 'rejected';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client_cr), 'Disallowed for manual poi status rejected';

    $manual_status = 'none';

    $onfido_status = 'expired';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client_cr), 'Disallowed for onfido poi status expired';

    $onfido_status = 'rejected';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client_cr), 'Disallowed for onfido poi status rejected';

    $onfido_status = 'none';

    ok !BOM::User::IdentityVerification::is_idv_disallowed($client_cr), 'IDV is allowed for this client';

    $mocked_lc->unmock_all;
    $mocked_cli->unmock_all;
};

subtest 'is_idv_disallowed (moved from rpc utility)' => sub {
    my $mock_data = {};

    my $status_mock = Test::MockObject->new();
    my $lc_mock     = Test::MockObject->new();
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $client      = BOM::User::Client->rnew();

    $client_mock->mock(
        'landing_company',
        sub {
            return $lc_mock;
        });

    $client_mock->mock(
        'residence',
        sub {
            return $mock_data->{residence};
        });

    $client_mock->mock(
        'get_manual_poi_status',
        sub {
            return $mock_data->{get_manual_poi_status};
        });

    $client_mock->mock(
        'get_onfido_status',
        sub {
            return $mock_data->{get_onfido_status};
        });

    $client_mock->mock(
        'status',
        sub {
            return $status_mock;
        });

    $client_mock->mock(
        'aml_risk_classification',
        sub {
            return $mock_data->{aml_risk_classification};
        });

    $client_mock->mock(
        'get_idv_status',
        sub {
            return $mock_data->{get_idv_status};
        });

    $status_mock->mock(
        'allow_poi_resubmission',
        sub {
            return $mock_data->{allow_poi_resubmission};
        });

    $status_mock->mock(
        'allow_document_upload',
        sub {
            return $mock_data->{allow_document_upload};
        });

    $status_mock->mock(
        'unwelcome',
        sub {
            return $mock_data->{unwelcome};
        });

    $status_mock->mock(
        'age_verification',
        sub {
            return $mock_data->{age_verification};
        });

    $lc_mock->mock(
        'short',
        sub {
            return $mock_data->{short};
        });

    $mock_data->{unwelcome} = 1;
    $mock_data->{short}     = 'svg';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client), 'Disallowed for unwelcome client';

    $mock_data->{unwelcome} = 0;
    $mock_data->{short}     = 'malta';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client), 'Disallowed for non svg LC';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'high';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client), 'Disallowed for high AML risk';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 1;

    ok BOM::User::IdentityVerification::is_idv_disallowed($client), 'Disallowed for non expired age verified';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 1;

    ok BOM::User::IdentityVerification::is_idv_disallowed($client), 'Disallowed for allow poi resubmission status';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 0;
    $mock_data->{allow_document_upload}   = {reason => 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT'};
    $mock_data->{get_manual_poi_status}   = 'rejected';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client), 'Disallowed for manual POI rejected status';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 0;
    $mock_data->{allow_document_upload}   = {reason => 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT'};
    $mock_data->{get_manual_poi_status}   = 'expired';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client), 'Disallowed for manual POI expired status';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 0;
    $mock_data->{allow_document_upload}   = {reason => 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT'};
    $mock_data->{get_manual_poi_status}   = 'none';
    $mock_data->{get_onfido_status}       = 'expired';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client), 'Disallowed for onfido expired status';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 0;
    $mock_data->{allow_document_upload}   = {reason => 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT'};
    $mock_data->{get_manual_poi_status}   = 'none';
    $mock_data->{get_onfido_status}       = 'rejected';

    ok BOM::User::IdentityVerification::is_idv_disallowed($client), 'Disallowed for onfido rejected status';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 0;
    $mock_data->{allow_document_upload}   = {reason => 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT'};
    $mock_data->{get_manual_poi_status}   = 'none';
    $mock_data->{get_onfido_status}       = 'none';
    $mock_data->{residence}               = 'br';

    ok !BOM::User::IdentityVerification::is_idv_disallowed($client), 'IDV allowed when all conditions are met';

    for my $reason (
        qw/FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT CRYPTO_TO_CRYPTO_TRANSFER_OVERLIMIT CRYPTO_TO_FIAT_TRANSFER_OVERLIMIT P2P_ADVERTISER_CREATED/)
    {
        $mock_data->{allow_document_upload} = {reason => $reason};

        ok !BOM::User::IdentityVerification::is_idv_disallowed($client), 'IDV allowed for doc upload reason: ' . $reason;
    }

    $mock_data->{age_verification} = 1;
    $mock_data->{get_idv_status}   = 'expired';
    ok !BOM::User::IdentityVerification::is_idv_disallowed($client), 'IDV allowed for age verified status when idv status is expired';

    $client_mock->unmock_all;
};

done_testing();
