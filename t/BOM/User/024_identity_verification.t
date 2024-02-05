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
use BOM::Config::Redis;
use BOM::Database::UserDB;
use Date::Utility;

use JSON::MaybeUTF8 qw( decode_json_utf8 encode_json_utf8 );

use constant IDV_REQUEST_PER_USER_PREFIX => 'IDV::REQUEST::PER::USER::';
use constant IDV_LOCK_PENDING            => 'IDV::LOCK::PENDING::';

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
            type            => 'sejeli',
            additional      => 'addme',
        });
    }
    'document added successfully';

    my $document = $user_cr->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM idv.document WHERE binary_user_id=?::BIGINT', undef, $client_cr->binary_user_id);
        });

    is $document->{issuing_country},     'ir',      'issuing country persisted';
    is $document->{status},              'pending', 'status is set to pending correctly';
    is $document->{expiration_date},     undef,     'expiration date not set correctly';
    is $document->{document_additional}, 'addme',   'additional has been set correctly';

    lives_ok {
        $idv_model_cmf->add_document({
            issuing_country => 'ir',
            number          => 'abcd9876',
            type            => 'melli-card',
            expiration_date => '2085-30-30',
        });
    }
    'document re-added with invalid expiration date';

    $document = $user_cr->dbic->run(
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
            expiration_date => 'Not Available',
        });
    }
    'document re-added with not available expiration date';

    $document = $user_cr->dbic->run(
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
            expiration_date => '',
        });
    }
    'document re-added empty string expiration date';

    $document = $user_cr->dbic->run(
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
        local $SIG{__WARN__} = sub { };
        $idv_model_nx->add_document({
            issuing_country => 'ir',
            number          => '1234',
            type            => 'sejeli'
        });
    }
    qr/is not present in table "binary_user"/, 'add document failed due to not existent user';

    throws_ok {
        local $SIG{__WARN__} = sub { };
        $idv_model_ccr->add_document();
    }
    qr/issuing_country/, 'missing issuing country';

    throws_ok {
        local $SIG{__WARN__} = sub { };
        $idv_model_ccr->add_document({issuing_country => 'ir'});
    }
    qr/number/, 'missing document number';

    throws_ok {
        local $SIG{__WARN__} = sub { };
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
        local $SIG{__WARN__} = sub { };
        $idv_model_nx->update_document_check({document_id => -1});
    }
    qr/The document you are looking for is not there/, 'update failed due to not existent document';

    throws_ok {
        local $SIG{__WARN__} = sub { };
        $idv_model_ccr->update_document_check();
    }
    qr/document_id/, 'missing document_id';

    throws_ok {
        local $SIG{__WARN__} = sub { };
        $idv_model_ccr->update_document_check({
            document_id => $document->{id},
            provider    => 'not exists provider'
        });
    }
    qr/invalid input value for enum idv.provider/, 'invalid provider';

    throws_ok {
        local $SIG{__WARN__} = sub { };
        $idv_model_ccr->update_document_check({
            document_id => $document->{id},
            status      => 'not exists status'
        });
    }
    qr/invalid input value for enum idv.check_status/, 'invalid check status';

    subtest 'deferred status' => sub {
        lives_ok {
            $idv_model_ccr->update_document_check({
                document_id => $document->{id},
                status      => 'deferred',
                messages    => ['got', undef, 'cha'],
                provider    => 'smile_identity'
            });
        }
        'document updated sucessfully';

        lives_ok {
            $document = $idv_model_ccr->get_last_updated_document();
        }
        'last updated document fetched';

        is $document->{status}, 'deferred', 'deferred status mapped to pending';

        $idv_model_ccr->status, 'pending', 'status is mapped to pending';
    };

    subtest 'photo id' => sub {
        lives_ok {
            $idv_model_ccr->update_document_check({
                document_id => $document->{id},
                status      => 'verified',
                messages    => [],
                provider    => 'smile_identity',
                photo       => [121, 131],         # can be arrayref
            });
        }
        'document updated sucessfully';

        lives_ok {
            my $dbic = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;

            my $check = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
                });

            cmp_deeply $check, [{photo_id => [121, 131]}], 'Photo ID returned';
        }
        'last updated document fetched';

        lives_ok {
            $idv_model_ccr->update_document_check({
                document_id => $document->{id},
                status      => 'verified',
                messages    => [],
                provider    => 'smile_identity',
                photo       => [],                 # can be empty arrayref
            });
        }
        'document updated sucessfully';

        lives_ok {
            my $dbic = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;

            my $check = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
                });

            cmp_deeply $check, [{photo_id => []}], 'Photo ID returned';
        }
        'last updated document fetched';

        lives_ok {
            $idv_model_ccr->update_document_check({
                document_id => $document->{id},
                status      => 'verified',
                messages    => [],
                provider    => 'smile_identity',
                photo       => 1515,               # can be number
            });
        }
        'document updated sucessfully';

        lives_ok {
            my $dbic = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;

            my $check = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
                });

            cmp_deeply $check, [{photo_id => [1515]}], 'Photo ID returned';
        }
        'last updated document fetched';

        lives_ok {
            $idv_model_ccr->update_document_check({
                document_id => $document->{id},
                status      => 'verified',
                messages    => [],
                provider    => 'smile_identity',
                photo       => undef,              # can be undef
            });
        }
        'document updated sucessfully';

        lives_ok {
            my $dbic = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;

            my $check = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
                });

            cmp_deeply $check, [{photo_id => []}], 'Photo ID returned';
        }
        'last updated document fetched';

        lives_ok {
            $idv_model_ccr->update_document_check({
                document_id => $document->{id},
                status      => 'verified',
                messages    => [],
                provider    => 'smile_identity',
                # could be missing
            });
        }
        'document updated sucessfully';

        lives_ok {
            my $dbic = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;

            my $check = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
                });

            cmp_deeply $check, [{photo_id => []}], 'Photo ID returned';
        }
        'last updated document fetched';

    };
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
        local $SIG{__WARN__} = sub { };
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
        local $SIG{__WARN__} = sub { };
        $idv_model_ccr->get_claimed_documents();
    }
    qr/issuing_country/, 'missing issuing_country';
};

subtest 'Submissions Left' => sub {
    is $idv_model_ccr->submissions_left($client_mf), 2, 'Expected submissions left';
};

subtest 'Limit per user' => sub {
    is $idv_model_ccr->limit_per_user($client_cr), 2, 'Expected limit per user';
};

subtest 'Incr submissions' => sub {
    $idv_model_ccr->incr_submissions;
    is $idv_model_ccr->submissions_left, 1, 'Expected submissions left';

    $idv_model_ccr->incr_submissions;
    is $idv_model_ccr->submissions_left, 0, 'Expected submissions left';

    $idv_model_ccr->incr_submissions;
    is $idv_model_ccr->submissions_left, 0, 'Expected submissions left (does not cross the limit)';

    subtest 'reset attempts' => sub {
        $idv_model_ccr->reset_attempts();
        is $idv_model_ccr->submissions_left, 2, 'The attempts of the client have come back';
    };
};

subtest 'Decr submissions' => sub {
    $idv_model_ccr->decr_submissions;
    is $idv_model_ccr->submissions_left, 3, 'Expected submissions left';
};

subtest 'Reset submissions to zero' => sub {
    is $idv_model_ccr->submissions_left, 3, 'Expected submissions left is correct';
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
        email    => 'cr+idv+disallowed@binary.com',
        password => 'hello',
    );
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user_cr->id,
    });
    $user_cr->add_client($client_cr);

    my $user_mf = BOM::User->create(
        email    => 'mf+idv+disallowed@binary.com',
        password => 'bye',
    );
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        binary_user_id => $user_mf->id,
    });
    $user_mf->add_client($client_mf);

    my $mocked_cli = Test::MockModule->new('BOM::User::Client');
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

    my $short;
    $short = 'svg';
    ok !BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr, landing_company => $short}), 'Allowed for svg (LC from argument)';
    ok !BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}),                            'Allowed for svg (LC from client)';

    $short = 'maltainvest';
    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_mf}), 'Disallowed for maltainvest (LC from client)';
    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr, landing_company => $short}),
        'Disallowed for maltainvest (LC from argument)';

    $short = 'bvi';
    ok !BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr, landing_company => $short}), 'Allowed for bvi (LC from argument)';

    $client_cr->status->set('unwelcome', 'test', 'test');

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for unwelcome clients';

    $client_cr->status->clear_unwelcome();

    $client_cr->status->_build_all();

    $client_cr->aml_risk_classification('high');

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for AML high risk clients';

    $client_cr->aml_risk_classification('low');

    $client_cr->status->set('age_verification', 'test', 'test');

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for age verified clients';

    $client_cr->status->clear_age_verification();

    $client_cr->status->set('allow_poi_resubmission', 'test', 'test');

    $client_cr->status->_build_all();

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for poi resubmissions';

    $client_cr->status->clear_allow_poi_resubmission();

    $client_cr->status->set('allow_document_upload', 'test', 'test');

    $client_cr->status->_build_all();

    $manual_status = 'expired';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for manual poi status expired';

    $manual_status = 'rejected';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for manual poi status rejected';

    $manual_status = 'none';

    $onfido_status = 'expired';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for onfido poi status expired';

    $onfido_status = 'rejected';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for onfido poi status rejected';

    $onfido_status = 'none';

    ok !BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'IDV is allowed for this client';

    $mocked_cli->unmock_all;
};

subtest 'identity verification requested' => sub {
    my $emit_mocker = Test::MockModule->new('BOM::Platform::Event::Emitter');

    my $emission = +{};

    $emit_mocker->mock(
        'emit',
        sub {
            $emission = +{@_};

            return 1;
        });

    my $redis = BOM::Config::Redis::redis_events();
    $redis->del(IDV_REQUEST_PER_USER_PREFIX . $idv_model_ccr->user_id);

    ok $idv_model_ccr->identity_verification_requested($client_cr), 'IDV succesfully requested';
    ok $redis->ttl(IDV_LOCK_PENDING . $idv_model_ccr->user_id) > 0, 'there is a TTL';
    is $idv_model_ccr->submissions_left(), 1, 'submission left decreased';

    cmp_deeply $emission, +{identity_verification_requested => {loginid => 'CR10000'}}, 'Expected emitted event';

    is $idv_model_ccr->get_pending_lock, 2, 'There is a redis lock';

    ok !$idv_model_ccr->identity_verification_requested($client_cr), 'IDV did not make it';

    is $client_cr->get_idv_status, 'pending', 'Pending due to IDV request lock';

    $log->contains_ok(qr/Unexpected IDV request when pending flag is still alive, user:/, 'expected log found');

    $idv_model_ccr->remove_lock();

    ok !$idv_model_ccr->get_pending_lock, 'There isn\'t a redis lock';
};

subtest 'is_idv_disallowed (moved from rpc utility)' => sub {
    my $user_cr = BOM::User->create(
        email    => 'cr+idv+disallowed+rpc@binary.com',
        password => 'hello',
    );
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user_cr->id,
    });
    $user_cr->add_client($client_cr);

    my $user_mf = BOM::User->create(
        email    => 'mf+idv+disallowed+rpc@binary.com',
        password => 'bye',
    );
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        binary_user_id => $user_mf->id,
    });
    $user_mf->add_client($client_mf);

    my $mock_data = {};

    my $status_mock = Test::MockObject->new();

    my $client_mock = Test::MockModule->new('BOM::User::Client');

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

    $mock_data->{unwelcome} = 1;
    $mock_data->{short}     = 'svg';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for unwelcome client';

    $mock_data->{unwelcome} = 0;
    $mock_data->{short}     = 'malta';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_mf}), 'Disallowed for non svg LC';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'high';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for high AML risk';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 1;

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for non expired age verified';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 1;

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for allow poi resubmission status';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 0;
    $mock_data->{allow_document_upload}   = {reason => 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT'};
    $mock_data->{get_manual_poi_status}   = 'rejected';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for manual POI rejected status';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 0;
    $mock_data->{allow_document_upload}   = {reason => 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT'};
    $mock_data->{get_manual_poi_status}   = 'expired';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for manual POI expired status';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 0;
    $mock_data->{allow_document_upload}   = {reason => 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT'};
    $mock_data->{get_manual_poi_status}   = 'none';
    $mock_data->{get_onfido_status}       = 'expired';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for onfido expired status';

    $mock_data->{unwelcome}               = 0;
    $mock_data->{short}                   = 'svg';
    $mock_data->{aml_risk_classification} = 'low';
    $mock_data->{get_idv_status}          = 'none';
    $mock_data->{age_verification}        = 0;
    $mock_data->{allow_poi_resubmission}  = 0;
    $mock_data->{allow_document_upload}   = {reason => 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT'};
    $mock_data->{get_manual_poi_status}   = 'none';
    $mock_data->{get_onfido_status}       = 'rejected';

    ok BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'Disallowed for onfido rejected status';

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

    ok !BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'IDV allowed when all conditions are met';

    for my $reason (
        qw/FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT CRYPTO_TO_CRYPTO_TRANSFER_OVERLIMIT CRYPTO_TO_FIAT_TRANSFER_OVERLIMIT P2P_ADVERTISER_CREATED/)
    {
        $mock_data->{allow_document_upload} = {reason => $reason};

        ok !BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'IDV allowed for doc upload reason: ' . $reason;
    }

    $mock_data->{age_verification} = 1;
    $mock_data->{get_idv_status}   = 'expired';
    ok !BOM::User::IdentityVerification::is_idv_disallowed({client => $client_cr}), 'IDV allowed for age verified status when idv status is expired';

    $client_mock->unmock_all;
};

subtest 'is idv revoked' => sub {
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $is_idv_validated;
    my $idv_status;
    my $poi_status;

    $client_mock->mock(
        'is_idv_validated',
        sub {
            return $is_idv_validated;
        });

    $client_mock->mock(
        'get_idv_status',
        sub {
            return $idv_status;
        });

    $client_mock->mock(
        'get_poi_status',
        sub {
            return $poi_status;
        });

    my $tests = [{
            result           => 1,
            is_idv_validated => 1,
            idv_status       => 'verified',
            poi_status       => 'none'
        },
        {
            result           => 0,
            is_idv_validated => 0,
            idv_status       => 'verified',
            poi_status       => 'none'
        },
        {
            result           => 0,
            is_idv_validated => 1,
            idv_status       => 'none',
            poi_status       => 'none'
        },
        {
            result           => 0,
            is_idv_validated => 1,
            idv_status       => 'verified',
            poi_status       => 'verified'
        }];

    for my $test ($tests->@*) {
        ($is_idv_validated, $idv_status, $poi_status) = @{$test}{qw/is_idv_validated idv_status poi_status/};

        if ($test->{result}) {
            ok BOM::User::IdentityVerification::is_idv_revoked($client_cr), 'expected truthy';
        } else {
            ok !BOM::User::IdentityVerification::is_idv_revoked($client_cr), 'expected falsey';
        }
    }
};

subtest 'is underage blocked' => sub {
    ok !$idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '12345',
            type            => 'cpf',
        }
        ),
        'document is not underage blocked';

    my $document = $idv_model_ccr->add_document({
        issuing_country => 'br',
        number          => '12345',
        type            => 'cpf',
    });

    ok !$idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '12345',
            type            => 'cpf',
        }
        ),
        'document is not yet underage blocked';

    $idv_model_ccr->update_document_check({
        document_id => $document->{id},
        status      => 'verified',
        messages    => ['UNDERAGE'],
        provider    => 'zaig'
    });

    is $idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '12345',
            type            => 'cpf',
        }
        ),
        $client_cr->binary_user_id,
        'document is underage blocked';

    ok !$idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '123456',
            type            => 'cpf',
            additional      => 'test',
        }
        ),
        'other document is not underage blocked';

    ok !$idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '123456',
            type            => 'cpf',
        }
        ),
        'other document is not underage blocked';

    $document = $idv_model_ccr->add_document({
        issuing_country => 'br',
        number          => '123456',
        type            => 'cpf',
        additional      => 'test',
    });

    ok !$idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '123456',
            type            => 'cpf',
        }
        ),
        'other document is not underage blocked';

    $idv_model_ccr->update_document_check({
        document_id => $document->{id},
        status      => 'verified',
        messages    => ['UNDERAGE'],
        provider    => 'zaig'
    });

    ok !$idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '123456',
            type            => 'cpf',
        }
        ),
        'other document is not underage blocked';

    is $idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '123456',
            type            => 'cpf',
            additional      => 'test'
        }
        ),
        $client_cr->binary_user_id,
        'other document with additional is underage blocked';

    # client became legal age
    $idv_model_ccr->update_document_check({
            document_id => $document->{id},
            status      => 'verified',
            messages    => ['UNDERAGE'],
            provider    => 'zaig',
            report      => encode_json_utf8({birthdate => Date::Utility->new->minus_time_interval('18y')->date_yyyymmdd})});

    ok !$idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '123456',
            type            => 'cpf',
            additional      => 'test'
        }
        ),
        'became legal age';

    # client became underage age
    $idv_model_ccr->update_document_check({
            document_id => $document->{id},
            status      => 'verified',
            messages    => ['UNDERAGE'],
            provider    => 'zaig',
            report      => encode_json_utf8({birthdate => Date::Utility->new->minus_time_interval('18y')->plus_time_interval('1d')->date_yyyymmdd})});

    is $idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '123456',
            type            => 'cpf',
            additional      => 'test'
        }
        ),
        $client_cr->binary_user_id,
        'became underage';

    # client became legal age
    $idv_model_ccr->update_document_check({
            document_id => $document->{id},
            status      => 'verified',
            messages    => ['UNDERAGE'],
            provider    => 'zaig',
            report      => encode_json_utf8({birthdate => Date::Utility->new->minus_time_interval('18y')->minus_time_interval('1d')->date_yyyymmdd})}
    );

    ok !$idv_model_ccr->is_underage_blocked({
            issuing_country => 'br',
            number          => '123456',
            type            => 'cpf',
            additional      => 'test'
        }
        ),
        'became legal age';

};

subtest 'idv opt out' => sub {
    my $country;

    throws_ok {
        local $SIG{__WARN__} = sub { };
        $idv_model_ccr->add_opt_out($country);
    }
    qr/country/, 'country is required for adding opt out';

    $country = 'ke';
    lives_ok {
        $idv_model_ccr->add_opt_out($country);
    }
    'opt out added successfully';

    lives_ok {
        $idv_model_ccr->add_opt_out($country);
    }
    'opt out added successfully for same user, same country';

    $country = 'ug';
    lives_ok {
        $idv_model_ccr->add_opt_out($country);
    }
    'opt out added successfully for same user, different country';

};

subtest 'is available' => sub {
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $user_cr = BOM::User->create(
        email    => 'is_available@deriv.com',
        password => 'secret_pwd'
    );

    $user_cr->add_client($client_cr);

    my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');
    # mocks idv_submissions_left has_expired_document_chance idv_disallowed

    my $client_mock = Test::MockModule->new('BOM::User::Client');
    # mocks idv_status

    my $utility_mock = Test::MockModule->new('BOM::Platform::Utility');
    # mocks has_idv

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $user_cr->id);

    my $test_cases = [{
            idv_submissions_left => 1,
            expected             => 1,
        },
        {
            has_idv  => 0,
            expected => 0,
        },
        {
            has_idv              => 1,
            idv_submissions_left => 1,
            idv_status           => 'none',
            expected             => 1,
        },
        {
            idv_submissions_left        => 0,
            idv_expired_document_chance => 1,
            idv_status                  => 'none',
            expected                    => 0,
        },
        {
            idv_submissions_left        => 0,
            idv_expired_document_chance => 0,
            idv_status                  => 'expired',
            expected                    => 0,
        },
        {
            idv_submissions_left        => 0,
            idv_expired_document_chance => 1,
            idv_status                  => 'expired',
            expected                    => 1,
        },
        {
            idv_submissions_left        => 1,
            idv_expired_document_chance => 1,
            idv_status                  => 'expired',
            idv_disallowed              => 1,
            expected                    => 0,
        },
        {
            idv_submissions_left => 0,
            idv_status           => 'none',
            expected             => 0,
        }];

    for my $test_case ($test_cases->@*) {
        $client_mock->mock(get_idv_status => $test_case->{idv_status} // 'none');

        $utility_mock->mock(has_idv => $test_case->{has_idv} // 1);
        $idv_mock->mock(submissions_left            => $test_case->{idv_submissions_left}        // 0);
        $idv_mock->mock(has_expired_document_chance => $test_case->{idv_expired_document_chance} // 0);
        $idv_mock->mock(is_idv_disallowed           => $test_case->{idv_disallowed}              // 0);

        cmp_deeply($idv_model->is_available({client => $client_cr}), $test_case->{expected}, 'expected availability');
    }

    $client_mock->unmock_all;
    $idv_mock->unmock_all;
};

subtest 'supported documents' => sub {
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $user_cr = BOM::User->create(
        email    => 'supported_documents@deriv.com',
        password => 'secret_pwd'
    );

    $user_cr->add_client($client_cr);

    my $utility_mock = Test::MockModule->new('BOM::Platform::Utility');

    my $countries_mock = Test::MockModule->new('Brands::Countries');

    my $format         = '^123$';
    my $country_config = {
        ke => {
            config => {
                idv => {
                    document_types => {
                        national_id => {
                            display_name => 'National ID Number',
                            format       => $format,
                        },
                        passport => {
                            display_name => 'Passport',
                            format       => $format,
                            additional   => {
                                display_name => 'File Number',
                                format       => $format,
                            }
                        },
                        drivers_license => {
                            display_name => 'Drivers License',
                            format       => $format,
                            other        => 'big cat'
                        }}}
            },
            is_idv_supported => 1,
        }};
    $countries_mock->mock('countries_list', sub { return $country_config });

    my $expected_documents = $country_config->{ke}->{config}->{idv}->{document_types};
    delete $expected_documents->{drivers_license}->{other};

    my $test_cases = [{
            title        => 'country code not provided',
            country_code => undef,
            expected     => {}
        },
        {
            title        => 'invalid country code',
            country_code => 'xx',
            expected     => {}
        },
        {
            title        => 'idv not supported for country code',
            country_code => 'py',
            expected     => {}
        },
        {
            title        => 'valid country code, no idv',
            country_code => 'ke',
            has_idv      => 0,
            expected     => {}
        },
        {
            title        => 'valid country code',
            country_code => 'ke',
            expected     => $expected_documents
        }];

    for my $test_case ($test_cases->@*) {
        $utility_mock->mock(has_idv => $test_case->{has_idv} // 1);
        my $country_code = $test_case->{country_code};
        cmp_deeply BOM::User::IdentityVerification::supported_documents($country_code), $test_case->{expected}, $test_case->{title};
    }

    $utility_mock->unmock_all;
    $countries_mock->unmock_all;
};

done_testing();
