use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use BOM::User::Client;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Date::Utility;
use List::Util;
use LandingCompany::Registry;

my $mocked_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
my $uploaded;

$mocked_documents->mock(
    'uploaded',
    sub {
        my $self = shift;
        $self->_clear_uploaded;
        return $uploaded;
    });

my $expirable_doc = {
    test_document => {
        type => 'passport',
    },
};

subtest 'get_poa_status' => sub {
    subtest 'Unregulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        my $user = BOM::User->create(
            email          => 'emailtest1@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_cr);

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        subtest 'POA status none' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 0,
                    documents   => {},
                }};

            is $test_client_cr->get_poa_status, 'none', 'Client POA status is none';
            $mocked_client->unmock_all;
        };

        subtest 'POA status pending' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 1,
                    is_rejected => 0,
                    documents   => {},
                }};

            is $test_client_cr->get_poa_status, 'pending', 'Client POA status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POA status rejected' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 1,
                    documents   => {},
                }};

            is $test_client_cr->get_poa_status, 'rejected', 'Client POA status is rejected';
            $mocked_client->unmock_all;
        };

        subtest 'POA status verified' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 1 });

            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 0,
                    documents   => {},
                }};

            is $test_client_cr->get_poa_status, 'verified', 'Client POA status is verified';
            $mocked_client->unmock_all;
        };

        subtest 'POA status outdated (expired)' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 0,
                    is_outdated => 1,
                    documents   => {},
                }};

            is $test_client_cr->get_poa_status, 'expired', 'Client POA status is expired';
            $mocked_client->unmock_all;
        };

        subtest 'POA status pending over outdated' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 1,
                    is_rejected => 0,
                    is_outdated => 1,
                    documents   => {},
                }};

            is $test_client_cr->get_poa_status, 'pending', 'Client POA status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POA status rejected over outdated' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 1,
                    is_outdated => 1,
                    documents   => {},
                }};

            is $test_client_cr->get_poa_status, 'rejected', 'Client POA status is rejected';
            $mocked_client->unmock_all;
        };

        subtest 'POA status outdated over verified' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 0,
                    is_outdated => 1,
                    is_verified => 1,
                    documents   => {},
                }};

            is $test_client_cr->get_poa_status, 'expired', 'Client POA status is outdated';
            $mocked_client->unmock_all;
        };

        subtest 'fully auth by IDV + high risk' => sub {
            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 0,
                    documents   => {},
                }};

            $test_client_cr->set_authentication('IDV', {status => 'pass'});
            $test_client_cr->aml_risk_classification('high');
            $test_client_cr->save;

            is $test_client_cr->get_poa_status, 'none', 'Client POA status is none';
            $mocked_client->unmock_all;
        };

        subtest 'fully auth by IDV + high risk - rejected' => sub {
            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 1,
                    documents   => {},
                }};

            $test_client_cr->set_authentication('IDV', {status => 'pass'});
            $test_client_cr->aml_risk_classification('high');
            $test_client_cr->save;

            is $test_client_cr->get_poa_status, 'rejected', 'Client POA status is rejected';
            $mocked_client->unmock_all;
        };

        subtest 'fully auth by IDV + high risk - expired' => sub {
            $uploaded = {
                proof_of_address => {
                    is_outdated => 1,
                    is_pending  => 0,
                    is_rejected => 0,
                    documents   => {},
                }};

            $test_client_cr->set_authentication('IDV', {status => 'pass'});
            $test_client_cr->aml_risk_classification('high');
            $test_client_cr->save;

            is $test_client_cr->get_poa_status, 'expired', 'Client POA status is expired';
            $mocked_client->unmock_all;
        };

        subtest 'fully auth (not by IDV) + high risk' => sub {
            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 0,
                    documents   => {},
                }};

            $test_client_cr->set_authentication('ID_ONLINE', {status => 'pass'});
            $test_client_cr->aml_risk_classification('high');
            $test_client_cr->save;

            is $test_client_cr->get_poa_status, 'verified', 'Client POA status is verified';
            $mocked_client->unmock_all;
        };
    };

    subtest 'Regulated account' => sub {
        my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my $user = BOM::User->create(
            email          => 'emailtest2@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_mf);

        my $mocked_client = Test::MockModule->new(ref($test_client_mf));
        subtest 'POA status none' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 0,
                    documents   => {},
                }};

            is $test_client_mf->get_poa_status, 'none', 'Client POA status is none';
            $mocked_client->unmock_all;
        };

        subtest 'POA status pending' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 1,
                    is_rejected => 0,
                    documents   => {},
                }};

            is $test_client_mf->get_poa_status, 'pending', 'Client POA status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POA status rejected' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 1,
                    documents   => {},
                }};

            is $test_client_mf->get_poa_status, 'rejected', 'Client POA status is rejected';
            $mocked_client->unmock_all;
        };

        subtest 'POA status verified' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 1 });

            $uploaded = {
                proof_of_address => {
                    is_expired  => 0,
                    is_pending  => 0,
                    is_rejected => 0,
                    documents   => {},
                }};

            is $test_client_mf->get_poa_status, 'verified', 'Client POA status is verified';
            $mocked_client->unmock_all;
        };
    };
};

subtest 'get_poi_status' => sub {
    my @latest_poi_by;
    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    my ($onfido_document_status, $onfido_sub_result, $user_check_result);
    $mocked_onfido->mock(
        'get_latest_check',
        sub {
            return {
                user_check => {
                    result => $user_check_result,
                },
                report_document_status     => $onfido_document_status,
                report_document_sub_result => $onfido_sub_result,
            };
        });

    subtest 'Unregulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        my $user = BOM::User->create(
            email          => 'emailtest3@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_cr);

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        subtest 'POI status none' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => $expirable_doc,
                }};

            is $test_client_cr->get_poi_status, 'none', 'Client POI status is none';
            $mocked_client->unmock_all;
        };

        subtest 'POI status expired for uploaded files' => sub {
            $mocked_client->mock('fully_authenticated',               sub { return 0 });
            $mocked_client->mock('latest_poi_by',                     sub { return @latest_poi_by });
            $mocked_client->mock('is_document_expiry_check_required', sub { return 1 });
            @latest_poi_by = ('manual');

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    documents  => $expirable_doc,
                }};

            is $test_client_cr->get_poi_status, 'expired', 'Client POI status is expired';
            $mocked_client->unmock_all;
        };

        subtest 'POI status expired for IDV' => sub {
            $mocked_client->mock(
                'latest_poi_by',
                sub {
                    return 'idv';
                });

            my $doc_mock = Test::MockModule->new('BOM::User::IdentityVerification');
            $doc_mock->mock(
                'get_last_updated_document',
                sub {
                    return {
                        document_id              => 1,
                        issuing_country          => 'br',
                        document_number          => 'BR-001',
                        document_type            => 'national_identity_card',
                        status                   => 'verified',
                        document_expiration_date => Date::Utility->new()->_minus_years(1),
                    };
                });

            is $test_client_cr->get_poi_status, 'expired', 'Client POI status is expired due to idv expired document';

            $doc_mock->unmock_all;
            $mocked_client->unmock_all;

        };

        subtest 'POI status pending' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $mocked_client->mock('latest_poi_by',       sub { return 'onfido' });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => $expirable_doc,
                }};

            $onfido_document_status = 'in_progress';
            is $test_client_cr->get_poi_status, 'pending', 'Client POI status is pending';
            $mocked_client->unmock_all;

            subtest 'pending is above everything' => sub {
                $mocked_client->mock('fully_authenticated', sub { return 0 });
                $mocked_client->mock('latest_poi_by',       sub { return 'onfido' });

                $uploaded = {
                    proof_of_identity => {
                        is_expired => 1,
                        documents  => $expirable_doc,
                    }};
                $onfido_document_status = 'in_progress';
                is $test_client_cr->get_poi_status, 'pending', 'Client POI status is still pending';
                $mocked_client->unmock_all;
            };
        };

        subtest 'POI status is pending' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $mocked_client->mock('latest_poi_by',       sub { return @latest_poi_by });
            @latest_poi_by = ('manual');

            $uploaded = {
                proof_of_identity => {
                    is_pending => 1,
                    documents  => {test => {}},
                }};

            $onfido_document_status = undef;
            is $test_client_cr->get_poi_status, 'pending', 'Client POI status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POI documents expired but onfido status in_progress' => sub {
            $onfido_document_status = 'in_progress';
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $mocked_client->mock('latest_poi_by',       sub { return 'onfido' });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    documents  => $expirable_doc,
                }};

            is $test_client_cr->get_poi_status, 'pending', 'Client POI status is pending';

            subtest 'even when fully authenticated' => sub {
                $mocked_client->mock('fully_authenticated', sub { return 1 });
                is $test_client_cr->get_poi_status, 'pending', 'Client POI status is still pending';
            };
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
                    documents  => $expirable_doc,
                }};

            is $test_client_cr->get_poi_status, 'rejected', 'Client POI status is rejected';
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
                    documents  => $expirable_doc,
                }};

            is $test_client_cr->get_poi_status, 'suspected', 'Client POI status is suspected';
            $mocked_client->unmock_all;
            $onfido_document_status = undef;
            $onfido_sub_result      = undef;
        };

        subtest 'POI status verified' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $mocked_client->mock('latest_poi_by',       sub { return @latest_poi_by });
            @latest_poi_by = ('manual');

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => $expirable_doc,
                }};

            is $test_client_cr->get_poi_status, 'verified', 'Client POI status is verified';
            $mocked_client->unmock_all;
        };

        subtest 'POI status rejected - fully authenticated or age verified' => sub {
            $test_client_cr->status->clear_age_verification;
            my $authenticated = 1;
            $mocked_client->mock('fully_authenticated',               sub { return $authenticated });
            $mocked_client->mock('latest_poi_by',                     sub { return 'onfido' });
            $mocked_client->mock('is_document_expiry_check_required', sub { return 1 });

            my $authenticated_test_scenarios = sub {
                $uploaded = {
                    onfido => {
                        is_expired => 0,
                        documents  => $expirable_doc,
                    }};
                $onfido_document_status = 'complete';
                $onfido_sub_result      = 'rejected';
                is $test_client_cr->get_poi_status, 'verified',
                    'POI status of an authenticated client is <verified> - even with rejected onfido check';

                $onfido_document_status = 'complete';
                $onfido_sub_result      = 'clear';
                $user_check_result      = 'clear';
                $uploaded               = {
                    onfido => {
                        is_expired => 1,
                        documents  => $expirable_doc,
                    }};
                is $test_client_cr->get_poi_status, 'expired', 'POI status of an authenticated client is <expired> - if expiry check is required';

                $onfido_document_status = 'complete';
                $onfido_sub_result      = 'rejected';
                $user_check_result      = 'consider';
                $uploaded               = {
                    onfido => {
                        is_expired => 1,
                        documents  => $expirable_doc,
                    }};
                is $test_client_cr->get_poi_status, 'rejected',
                    'POI status of an authenticated client is <rejected> - if expiry check is required and onfido result is not clear';
            };

            $authenticated = 1;
            $authenticated_test_scenarios->();

            $authenticated = 0;
            $test_client_cr->status->set('age_verification', 'system', 'test');
            $authenticated_test_scenarios->();

            $test_client_cr->status->clear_age_verification;

            $mocked_client->unmock_all;
        };

        subtest 'POI status suspected - fully authenticated or age verified' => sub {
            $test_client_cr->status->clear_age_verification;
            my $authenticated = 1;
            $mocked_client->mock('fully_authenticated',               sub { return $authenticated });
            $mocked_client->mock('latest_poi_by',                     sub { return 'onfido' });
            $mocked_client->mock('is_document_expiry_check_required', sub { return 1 });

            my $authenticated_test_scenarios = sub {
                $uploaded = {
                    onfido => {
                        is_expired => 0,
                        documents  => $expirable_doc,
                    }};
                $onfido_document_status = 'complete';
                $onfido_sub_result      = 'suspected';
                $user_check_result      = 'suspected';
                is $test_client_cr->get_poi_status, 'verified',
                    'POI status of an authenticated client is <verified> - even with suspected onfido check';

                $onfido_document_status = 'complete';
                $onfido_sub_result      = 'clear';
                $user_check_result      = 'clear';
                $uploaded               = {
                    onfido => {
                        is_expired => 1,
                        documents  => $expirable_doc,
                    }};
                is $test_client_cr->get_poi_status, 'expired', 'POI status of an authenticated client is <expired> - if expiry check is required';

                $onfido_document_status = 'complete';
                $onfido_sub_result      = 'suspected';
                $user_check_result      = 'suspected';
                $uploaded               = {
                    onfido => {
                        is_expired => 1,
                        documents  => $expirable_doc,
                    }};
                is $test_client_cr->get_poi_status, 'suspected',
                    'POI status of an authenticated client is <suspected> - if expiry check is required and onfido result is not clear';
            };

            $authenticated = 1;
            $authenticated_test_scenarios->();

            $authenticated = 0;
            $test_client_cr->status->set('age_verification', 'system', 'test');
            $authenticated_test_scenarios->();

            $test_client_cr->status->clear_age_verification;

            $mocked_client->unmock_all;
        };

        subtest 'IDV status is expired, but the client is age verified' => sub {
            $test_client_cr->status->clear_age_verification;
            my $authenticated = 1;
            my $idv_status;
            $mocked_client->mock('fully_authenticated',               sub { return $authenticated });
            $mocked_client->mock('latest_poi_by',                     sub { return 'idv' });
            $mocked_client->mock('is_document_expiry_check_required', sub { return 1 });
            $mocked_client->mock('get_idv_status',                    sub { return $idv_status });

            $onfido_document_status = 'complete';
            $onfido_sub_result      = 'clear';
            $uploaded               = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => $expirable_doc,
                }};

            $authenticated = 1;
            $idv_status    = 'expired';
            is $test_client_cr->get_poi_status, 'verified', 'POI status of an authenticated client is <verified> - even with idv expired';

            $authenticated = 0;
            $idv_status    = 'expired';
            is $test_client_cr->get_poi_status, 'expired', 'POI status of a non authenticated client is <expired> - with idv expired';

            $test_client_cr->status->clear_age_verification;

            $mocked_client->unmock_all;
        };

        subtest 'POI status reject - POI name mismatch' => sub {
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $uploaded               = {proof_of_identity => {documents => {}}};
            $onfido_document_status = 'complete';
            $onfido_sub_result      = 'clear';
            $test_client_cr->status->clear_age_verification;
            $test_client_cr->status->setnx('poi_name_mismatch', 'test', 'test');

            is $test_client_cr->get_poi_status, 'rejected', 'Rejected when POI name mismatch reported';

            $test_client_cr->status->clear_poi_name_mismatch;
            is $test_client_cr->get_poi_status, 'none', 'Non rejected when POI name mismatch is cleared';

            $mocked_client->unmock_all;
        };

        subtest 'POI status reject - POI dob mismatch' => sub {
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $uploaded               = {proof_of_identity => {documents => {}}};
            $onfido_document_status = 'complete';
            $onfido_sub_result      = 'clear';
            $test_client_cr->status->clear_age_verification;
            $test_client_cr->status->setnx('poi_dob_mismatch', 'test', 'test');

            is $test_client_cr->get_poi_status, 'rejected', 'Rejected when POI dob mismatch reported';

            $test_client_cr->status->clear_poi_dob_mismatch;
            is $test_client_cr->get_poi_status, 'none', 'Non rejected when POI dob mismatch is cleared';

            $mocked_client->unmock_all;
        };

        subtest 'First Onfido upload and no check was made just yet' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $mocked_client->mock('latest_poi_by',       sub { return undef });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => $expirable_doc,
                }};

            $onfido_document_status = undef;
            $onfido_sub_result      = undef;

            is $test_client_cr->get_poi_status, 'none', 'Client POI should be none';
            my $pending_request = 1;

            $mocked_onfido->mock(
                'pending_request',
                sub {
                    return $pending_request;
                });

            $mocked_client->mock('latest_poi_by', sub { return 'onfido' });
            is $test_client_cr->get_poi_status, 'pending', 'Client POI status is pending';

            $pending_request = 0;
            is $test_client_cr->get_poi_status, 'none', 'Client POI should be none when the flag is liquidated';

            $pending_request = 1;
            is $test_client_cr->get_poi_status, 'pending', 'Client POI status is pending again';

            my $mocked_config = Test::MockModule->new('BOM::Config::Onfido');
            $mocked_config->mock(
                'is_country_supported',
                sub {
                    return 0;
                });

            is $test_client_cr->get_poi_status, 'none', 'On unsupported country scenario the maybe_pending kicks in';

            $mocked_config->unmock_all;
            $mocked_client->unmock_all;
            $pending_request = 0;
        };

        subtest 'POI status - IDV rejected first, then manual uploads' => sub {
            my $idv         = 'none';
            my @last_poi_by = ('idv');
            $mocked_client->mock('latest_poi_by', sub { return @last_poi_by });
            $mocked_client->mock(
                'get_idv_status',
                sub {
                    return $idv;
                });

            $uploaded = {};
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            is $test_client_cr->get_poi_status,        'none', 'poi status = none';
            is $test_client_cr->get_idv_status,        'none', 'idv status = none';
            is $test_client_cr->get_manual_poi_status, 'none', 'manual status = none';

            $idv = 'rejected';

            is $test_client_cr->get_poi_status,        'rejected', 'poi status = rejected';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'none',     'manual status = none';

            @last_poi_by = ('manual');
            $uploaded    = {
                proof_of_identity => {
                    is_pending => 1,
                    documents  => $expirable_doc,
                },
            };

            is $test_client_cr->get_poi_status,        'pending',  'poi status = pending';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'pending',  'manual status = pending';

            $uploaded = {
                proof_of_identity => {
                    is_pending => 0,
                    documents  => $expirable_doc,
                },
            };

            is $test_client_cr->get_poi_status,        'rejected', 'poi status = rejected';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'rejected', 'manual status = rejected';

            $uploaded = {
                proof_of_identity => {
                    is_pending => 0,
                    documents  => $expirable_doc,
                },
            };

            $test_client_cr->status->setnx('age_verification', 'gato', 'test');
            is $test_client_cr->get_poi_status,        'verified', 'poi status = verified';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'verified', 'manual status = verified';

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    documents  => $expirable_doc,
                },
            };

            $mocked_client->mock('is_document_expiry_check_required', sub { return 1 });
            is $test_client_cr->get_poi_status,        'expired',  'poi status = expired';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'expired',  'manual status = expired';

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    is_pending => 1,
                    documents  => $expirable_doc,
                },
            };

            is $test_client_cr->get_poi_status,        'pending',  'poi status = pending';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'pending',  'manual status = pending';

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    is_pending => 0,
                    documents  => $expirable_doc,
                },
            };

            is $test_client_cr->get_poi_status,        'verified', 'poi status = verified';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'verified', 'manual status = verified';
        };

        subtest 'ignore age verification' => sub {
            my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });
            my $user = BOM::User->create(
                email          => 'emailtest3333333@email.com',
                password       => BOM::User::Password::hashpw('asdf12345'),
                email_verified => 1,
            );
            $user->add_client($test_client_cr);

            my $mocked_client = Test::MockModule->new(ref($test_client_cr));
            my $mocked_status = Test::MockModule->new(ref($test_client_cr->status));
            my $ignore_age_verification;

            $mocked_client->mock(
                'latest_poi_by',
                sub {
                    return 'idv';
                });

            $mocked_client->mock(
                'get_idv_status',
                sub {
                    return 'none';
                });
            $mocked_status->mock('age_verification',        sub { return 0 });
            $mocked_client->mock('fully_authenticated',     sub { return 1 });
            $mocked_client->mock('ignore_age_verification', sub { return $ignore_age_verification });
            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => $expirable_doc,
                }};

            $ignore_age_verification = 0;
            is $test_client_cr->get_poi_status, 'verified', 'verified when ignoring age verified is off';

            $ignore_age_verification = 1;
            is $test_client_cr->get_poi_status, 'none', 'none when ignoring age verified is on';

            $mocked_status->unmock_all;
        };

        $mocked_client->unmock_all;

    };

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
        my @last_poi_by   = ('manual');
        $mocked_client->mock('latest_poi_by',       sub { return @last_poi_by });
        $mocked_client->mock('fully_authenticated', sub { return 0 });

        subtest 'POI status none' => sub {
            $uploaded = {};
            is $test_client_mf->get_poi_status, 'none', 'Client POI status is none';
        };

        subtest 'POI status expired' => sub {
            $mocked_client->mock('is_document_expiry_check_required', sub { return 1 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    documents  => {test => 1},
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
                    documents  => $expirable_doc,
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
                    documents  => $expirable_doc,
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
                onfido => {
                    is_expired => 0,
                    documents  => $expirable_doc,
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
                    documents  => $expirable_doc,
                }};

            is $test_client_mf->get_poi_status, 'verified', 'Client POI status is verified';
            $mocked_client->unmock_all;
        };
        subtest 'POI status verified by manual' => sub {
            $mocked_client->mock('fully_authenticated',     sub { return 1 });
            $mocked_client->mock('get_manual_poi_status',   sub { return 'verified' });
            $mocked_client->mock('ignore_age_verification', sub { return 1 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => $expirable_doc,
                }};

            is $test_client_mf->get_poi_status, 'verified', 'Client POI status is verified by manual';
            $mocked_client->unmock_all;
        };
    };

    $mocked_onfido->unmock_all;
};

subtest 'needs_poa_verification' => sub {
    my $mocked_status = Test::MockModule->new('BOM::User::Client::Status');
    my $resubmission;

    $mocked_status->mock(
        'allow_poa_resubmission' => sub {
            return $resubmission;
        });

    subtest 'Unregulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        my $user = BOM::User->create(
            email          => 'emailtest5@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_cr);

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        subtest 'Not needed' => sub {
            $mocked_client->mock('get_poa_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });

            $uploaded = {
                proof_of_address => {
                    documents => {},
                }};

            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });

            ok !$test_client_cr->needs_poa_verification, 'POA is not needed';

            $mocked_client->mock('get_poa_status', sub { return 'pending' });
            ok !$test_client_cr->needs_poa_verification, 'POA is not needed when status is pending';

            subtest 'POA flag exception' => sub {
                $resubmission = 1;
                ok $test_client_cr->needs_poa_verification, 'POA resubmission flags has more weight';
                $resubmission = 0;
            };

            $mocked_client->unmock_all;
        };

        subtest 'Verification is needed' => sub {
            $mocked_client->mock('get_poa_status', sub { return 'expired' });

            $uploaded = {proof_of_address => {documents => undef}};

            ok $test_client_cr->needs_poa_verification, 'POA is needed due to expired POA status';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status', sub { return 'rejected' });
            $uploaded = {proof_of_address => {documents => undef}};

            ok $test_client_cr->needs_poa_verification, 'POA is needed due to rejected POA status';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status',           sub { return 'none' });
            $mocked_client->mock('fully_authenticated',      sub { return 0 });
            $mocked_client->mock('is_verification_required', sub { return 1 });
            $uploaded = {proof_of_address => {documents => undef}};

            ok $test_client_cr->needs_poa_verification, 'POA is needed due not fully authenticated and authentication needed';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status',           sub { return 'verified' });
            $mocked_client->mock('fully_authenticated',      sub { return 1 });
            $mocked_client->mock('is_verification_required', sub { return 0 });
            $uploaded = {
                proof_of_address => {
                    documents => {},
                }};

            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });
            $resubmission = 1;

            ok $test_client_cr->needs_poa_verification, 'POA is needed due to resubmission flag';
            $mocked_client->unmock_all;
            $resubmission = 0;
        };
    };

    subtest 'Regulated account' => sub {
        # Note for regulated accounts is_verification_required is expected to be true
        # no mock for that is needed.

        my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my $user = BOM::User->create(
            email          => 'emailtest6@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_mf);

        my $mocked_client = Test::MockModule->new(ref($test_client_mf));
        subtest 'Not needed' => sub {
            $mocked_client->mock('get_poa_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $uploaded = {
                proof_of_address => {
                    documents => {},
                }};

            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });

            ok !$test_client_mf->needs_poa_verification, 'POA is not needed';
            $mocked_client->unmock_all;
        };

        subtest 'Verification is needed' => sub {
            $mocked_client->mock('get_poa_status', sub { return 'expired' });
            $uploaded = {
                proof_of_address => {
                    documents => undef,
                }};

            ok $test_client_mf->needs_poa_verification, 'POA is needed due to expired POA status';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status', sub { return 'rejected' });
            $uploaded = {
                proof_of_address => {
                    documents => undef,
                }};

            ok $test_client_mf->needs_poa_verification, 'POA is needed due to rejected POA status';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status',      sub { return 'none' });
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $uploaded = {
                proof_of_address => {
                    documents => undef,
                }};
            ok !$test_client_mf->needs_poa_verification, 'POA is not needed before first deposit';
            $mocked_client->mock('has_deposits', sub { return 1 });
            ok $test_client_mf->needs_poa_verification, 'POA is needed due not fully authenticated and authentication needed';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $uploaded = {
                proof_of_address => {
                    documents => {},
                }};

            $mocked_client->mock(
                'binary_user_id' => sub {
                    return -1;
                });
            $resubmission = 1;

            ok $test_client_mf->needs_poa_verification, 'POA is needed due to resubmission flag';
            $mocked_client->unmock_all;
            $resubmission = 0;
        };
    };

    $mocked_status->unmock_all;
};

subtest 'needs_poi_verification' => sub {
    my ($onfido_sub_result, $onfido_applicant, $onfido_check);
    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    $mocked_onfido->mock(
        'get_latest_check',
        sub {
            return {
                report_document_sub_result => $onfido_sub_result,
                user_check                 => $onfido_check,
                user_applicant             => $onfido_applicant
            };
        });

    subtest 'Unregulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        my $user = BOM::User->create(
            email          => 'emailtest7@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_cr);

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        my $mocked_status = Test::MockModule->new(ref($test_client_cr->status));

        subtest 'Needed when verified' => sub {
            $mocked_client->mock('get_poi_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $mocked_status->mock(
                'age_verification',
                sub {
                    return {
                        staff_name         => 'system',
                        last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
                    };
                });
            $uploaded = {
                proof_of_address => {
                    documents => {},
                }};
            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });
            $mocked_client->mock(
                'is_high_risk' => sub {
                    return 0;
                });

            ok !$test_client_cr->needs_poi_verification, 'POI is not needed';

            $mocked_client->mock('get_poi_status', sub { return 'rejected' });
            ok $test_client_cr->needs_poi_verification, 'POI is needed for fully authenticated and age verified - when status is <rejected>';

            $mocked_client->unmock_all;
            $mocked_status->unmock_all;
        };

        subtest 'Not needed' => sub {
            $mocked_client->mock('get_poi_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $mocked_status->mock(
                'age_verification',
                sub {
                    return {
                        staff_name         => 'system',
                        last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
                    };
                });
            $uploaded = {
                proof_of_identity => {
                    documents => {},
                }};
            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });
            $mocked_client->mock(
                'is_high_risk' => sub {
                    return 0;
                });

            ok !$test_client_cr->needs_poi_verification, 'POI is not needed';

            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $uploaded = {
                proof_of_identity => {
                    documents => {},
                }};
            $onfido_check = undef;
            ok !$test_client_cr->needs_poi_verification, 'POI is not needed as the current status is pending';

            subtest 'POI flag exception' => sub {
                $mocked_status->mock('allow_poi_resubmission', sub { return 1 });
                ok $test_client_cr->needs_poi_verification, 'POI resubmission flags has more weight';
            };

            $mocked_client->unmock_all;
            $mocked_status->unmock_all;
        };

        subtest 'Not needed when manual poi verified' => sub {
            $mocked_client->mock('get_manual_poi_status', sub { return 'verified' });
            $mocked_client->mock('fully_authenticated',   sub { return 1 });
            $mocked_status->mock(
                'age_verification',
                sub {
                    return {
                        staff_name         => 'system',
                        last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
                    };
                });
            $uploaded = {
                proof_of_identity => {
                    documents => {},
                }};

            ok !$test_client_cr->needs_poi_verification, 'POI is not needed';

            $mocked_client->unmock_all;
            $mocked_status->unmock_all;
        };

        subtest 'Verification is needed' => sub {
            $mocked_client->mock('get_poi_status', sub { return 'expired' });
            $uploaded = {
                proof_of_address => {
                    documents => undef,
                }};

            ok $test_client_cr->needs_poi_verification, 'POI is needed due to expired POI status';
            $mocked_client->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $uploaded = {
                proof_of_identity => {
                    documents => {},
                }};

            ok $test_client_cr->needs_poi_verification, 'POI is needed due to verification required and current status is none';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 0 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $uploaded = {
                proof_of_identity => {
                    documents => undef,
                }};

            $onfido_sub_result = 'rejected';
            ok $test_client_cr->needs_poi_verification, 'POI is needed due to onfido rejected sub result';

            $onfido_sub_result = 'suspected';
            ok $test_client_cr->needs_poi_verification, 'POI is needed due to onfido suspected sub result';

            $onfido_sub_result = 'caution';
            ok $test_client_cr->needs_poi_verification, 'POI is needed due to onfido caution sub result';

            $mocked_client->mock('get_poi_status', sub { return 'expired' });
            ok $test_client_cr->needs_poi_verification, 'POI is needed due to onfido expired sub result';

            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 0 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $uploaded = {
                proof_of_address => {
                    documents => undef,
                }};

            ok !$test_client_cr->needs_poi_verification, 'POI is not needed as status is pendings';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $uploaded = {
                proof_of_identity => {
                    documents => undef,
                }};

            $onfido_sub_result = undef;
            $onfido_applicant  = undef;
            ok $test_client_cr->needs_poi_verification, 'POI is needed due to verification required and no POI documents seen';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $uploaded = {
                proof_of_identity => {
                    documents => {},
                }};

            $onfido_check = undef;
            ok $test_client_cr->needs_poi_verification, 'POI is needed due to verification required and no onfido check seen';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;
        };
    };

    subtest 'Regulated account' => sub {
        my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my $user = BOM::User->create(
            email          => 'emailtest8@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_mf);

        my $mocked_client = Test::MockModule->new(ref($test_client_mf));
        my $mocked_status = Test::MockModule->new(ref($test_client_mf->status));
        subtest 'Not needed' => sub {
            $mocked_client->mock('get_poi_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $mocked_status->mock(
                'age_verification',
                sub {
                    return {
                        staff_name         => 'system',
                        last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
                    };
                });
            $uploaded = {
                proof_of_address => {
                    documents => {},
                }};
            $mocked_client->mock(
                binary_user_id          => 'mocked',
                ignore_age_verification => 0,
            );

            ok !$test_client_mf->needs_poi_verification, 'POI is not needed';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $uploaded = {
                proof_of_identity => {
                    documents => {},
                }};

            $onfido_check = undef;
            ok !$test_client_mf->needs_poi_verification, 'POI is not needed as the current status is pending';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;
        };

        subtest 'Verification is needed' => sub {
            $mocked_client->mock('get_poi_status', sub { return 'expired' });
            $uploaded = {
                proof_of_address => {
                    documents => undef,
                }};

            ok $test_client_mf->needs_poi_verification, 'POI is needed due to expired POI status';
            $mocked_client->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $uploaded = {
                proof_of_address => {
                    documents => undef,
                }};

            ok $test_client_mf->needs_poi_verification, 'POI is needed due to verification required and current status is none';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $uploaded = {
                proof_of_identity => {
                    documents => undef,
                }};

            $onfido_sub_result = 'rejected';
            ok $test_client_mf->needs_poi_verification, 'POI is needed due to onfido rejected sub result';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $uploaded = {
                proof_of_identity => {
                    documents => undef,
                }};

            $onfido_sub_result = 'suspected';
            ok $test_client_mf->needs_poi_verification, 'POI is needed due to onfido suspected sub result';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $uploaded = {
                proof_of_identity => {
                    documents => undef,
                }};

            $onfido_sub_result = 'caution';
            ok $test_client_mf->needs_poi_verification, 'POI is needed due to onfido caution sub result';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $uploaded = {
                proof_of_identity => {
                    documents => undef,
                }};

            $onfido_sub_result = undef;
            $onfido_applicant  = undef;
            ok $test_client_mf->needs_poi_verification, 'POI is needed due to verification required and no POI documents seen';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $uploaded = {
                proof_of_identity => {
                    documents => {},
                }};

            $onfido_check = undef;
            ok $test_client_mf->needs_poi_verification, 'POI is needed due to verification required and no onfido check seen';

            $mocked_client->mock('get_poi_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $mocked_status->mock(
                'allow_poi_resubmission' => sub {
                    return 1;
                });

            ok $test_client_mf->needs_poi_verification, 'POI is needed due to resubmission flag';

            $mocked_client->unmock_all;
            $mocked_status->unmock_all;
        };
    };

    subtest 'when ignoring age verification' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        my $user = BOM::User->create(
            email          => 'emailtest13@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_cr);
        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        my $mocked_status = Test::MockModule->new(ref($test_client_cr->status));
        my $ignore_age_verification;
        $uploaded = {
            proof_of_identity => {
                documents => {},
            }};

        $mocked_client->mock('get_poi_status',      sub { return 'verified' });
        $mocked_client->mock('fully_authenticated', sub { return 1 });
        $mocked_status->mock(
            'age_verification',
            sub {
                return {
                    staff_name         => 'system',
                    last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
                };
            });
        $mocked_client->mock('ignore_age_verification', sub { return $ignore_age_verification; });

        $mocked_client->mock(
            'binary_user_id' => sub {
                return 'mocked';
            });

        # Test POI, risk low, idv_validated false
        $ignore_age_verification = 0;
        ok !$test_client_cr->needs_poi_verification, 'POI is not needed';

        $ignore_age_verification = 1;
        ok $test_client_cr->needs_poi_verification, 'POI is needed';

        $mocked_client->unmock_all;
        $mocked_status->unmock_all;

    };
};

subtest 'is_document_expiry_check_required' => sub {
    subtest 'Unregulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        my $user = BOM::User->create(
            email          => 'emailtest9@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_cr);

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        $mocked_client->mock('fully_authenticated', sub { return 0 });
        ok !$test_client_cr->landing_company->documents_expiration_check_required, 'Unregulated landing company does require expiration check';
        ok $test_client_cr->aml_risk_classification ne 'high',                     'Account aml risk is not high';
        # Now we are sure execution flow reaches our new fully_authenticated condition
        ok !$test_client_cr->fully_authenticated,               'Account is not fully authenticated';
        ok !$test_client_cr->is_document_expiry_check_required, "Not fully authenticated CR account doesn't have to check documents expiry";

        $mocked_client->mock('fully_authenticated', sub { return 1 });

        ok $test_client_cr->fully_authenticated,                'Account is fully authenticated';
        ok !$test_client_cr->is_document_expiry_check_required, "Fully authenticated CR account does not have to check documents expiry";
        $mocked_client->unmock_all;
    };

    subtest 'Regulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my $user = BOM::User->create(
            email          => 'emailtest10@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client_cr);

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        $mocked_client->mock('fully_authenticated', sub { return 0 });
        ok $test_client_cr->landing_company->documents_expiration_check_required, 'Regulated company does require expiration check';
        ok $test_client_cr->aml_risk_classification ne 'high',                    'Account aml risk is not high';
        ok !$test_client_cr->fully_authenticated,                                 'Account is not fully authenticated';
        ok $test_client_cr->is_document_expiry_check_required, "Not fully authenticated regulated account does have to check documents expiry";

        $mocked_client->mock('fully_authenticated', sub { return 1 });
        ok $test_client_cr->fully_authenticated,               'Account is fully authenticated';
        ok $test_client_cr->is_document_expiry_check_required, "Regulated account does have to check documents expiry";
        $mocked_client->unmock_all;
    };
};

subtest 'shared payment method' => sub {
    my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email          => 'emailtest11@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($test_client_cr);

    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    $mocked_onfido->mock(
        'get_latest_check',
        sub {
            return {};
        });

    my $mocked_client = Test::MockModule->new(ref($test_client_cr));
    $mocked_client->mock('is_verification_required', sub { return 0 });
    $mocked_client->mock('fully_authenticated',      sub { return 0 });
    $mocked_client->mock('age_verification',         sub { return 0 });
    $uploaded = {};

    my $mocked_status = Test::MockModule->new(ref($test_client_cr->status));
    $mocked_status->mock(
        'shared_payment_method',
        sub {
            return 1;
        });

    ok $test_client_cr->needs_poi_verification, 'Shared PM needs POI verification';

    $mocked_status->mock(
        'shared_payment_method',
        sub {
            return 0;
        });
    $mocked_client->mock(
        'binary_user_id' => sub {
            return -1;
        });

    ok !$test_client_cr->needs_poi_verification, 'Shared PM is gone and so does the needs POI verification';

    $mocked_client->unmock_all;
    $mocked_status->unmock_all;
    $mocked_onfido->unmock_all;
};

subtest 'false profile info' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'locked_for_false_info@email.com'
    });
    my $user = BOM::User->create(
        email          => 'locked_for_false_info@email.com',
        password       => "Coconut9009",
        email_verified => 1,
    );

    $user->add_client($client);

    ok !$client->needs_poi_verification, 'POI is not requrired in the begining';
    ok !$client->needs_poa_verification, 'POA is not requrired in the begining';

    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    $mocked_client->mock('locked_for_false_profile_info', sub { return 1 });

    ok $client->needs_poi_verification,  'POI is requrired because for false profile info';
    ok !$client->needs_poa_verification, 'POA is not requrired for false profile info';
};

subtest 'payment agent' => sub {
    my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    BOM::User->create(
        email    => 'pa_poa_poi@binary.com',
        password => 'asdf1234',
    )->add_client($test_client_cr);

    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    $mocked_onfido->mock(
        'get_latest_check',
        sub {
            return {};
        });

    my $mocked_client = Test::MockModule->new(ref($test_client_cr));
    $mocked_client->redefine('get_payment_agent', sub { return undef });

    ok !$test_client_cr->needs_poi_verification, 'POI is not required without PA';

    $mocked_client->redefine('get_payment_agent', sub { return 1 });
    ok $test_client_cr->needs_poi_verification, 'POI is required with PA';

    $mocked_client->unmock_all;
};

subtest 'First Deposit' => sub {
    subtest 'MLT' => sub {
        my $test_client = BOM::User::Client->rnew(
            password    => "hello",
            broker_code => 'MLT',
            residence   => 'de',
            citizen     => 'de',
            email       => 'nowthatsan@email.com',
            loginid     => 'MLT235711'
        );
        my $user = BOM::User->create(
            email          => 'nowthatsan@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client);
        $test_client->binary_user_id($user->id);

        my $mocked_client = Test::MockModule->new(ref($test_client));
        $mocked_client->mock('has_deposits', sub { return 1 });
        $uploaded = {};

        $mocked_client->mock('get_poi_status', sub { return 'none' });
        $mocked_client->mock('user',           sub { bless {}, 'BOM::User' });

        my $mocked_user = Test::MockModule->new('BOM::User');
        $mocked_user->mock('has_mt5_regulated_account', sub { return 0 });

        ok !$test_client->status->shared_payment_method, 'Not SPM';
        ok !$test_client->status->age_verification,      'Not age verified';
        ok !$test_client->fully_authenticated,           'Not fully authenticated';
        ok $test_client->is_verification_required(check_authentication_status => 1),
            'Verification required due to deposits on an unauthenticated MLT account';
        ok $test_client->needs_poi_verification, 'POI is needed for unauthenticated MLT account after first deposit';
        ok $test_client->needs_poa_verification, 'POA is needed for unauthenticated MLT account after first deposit';

        $mocked_client->mock('has_deposits', sub { return 0 });
        ok !$test_client->is_verification_required(check_authentication_status => 1),
            'Verification not required for an unauthenticated MLT account without deposits';
        ok !$test_client->needs_poi_verification, 'POI is not needed for unauthenticated MLT account without deposits';
        ok !$test_client->needs_poa_verification, 'POA is not needed for unauthenticated MLT account without deposits';

        $mocked_client->unmock_all;
        $mocked_user->unmock_all;
    };

    subtest 'MF' => sub {
        my $test_client = BOM::User::Client->rnew(
            broker_code => 'MF',
            residence   => 'de',
            citizen     => 'de',
            email       => 'nowthatsan@email.com',
            loginid     => 'MLT235711'
        );
        my $user = BOM::User->create(
            email          => 'nowthatsan2@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client);
        $test_client->binary_user_id($user->id);

        my $mocked_client = Test::MockModule->new(ref($test_client));
        $mocked_client->mock('has_deposits', sub { return 1 });
        $uploaded = {};

        $mocked_client->mock('get_poi_status', sub { return 'none' });
        $mocked_client->mock('user',           sub { bless {}, 'BOM::User' });

        my $mocked_user = Test::MockModule->new('BOM::User');
        $mocked_client->mock('has_mt5_regulated_account', sub { return 0 });

        ok !$test_client->status->shared_payment_method, 'Not SPM';
        ok !$test_client->status->age_verification,      'Not age verified';
        ok !$test_client->fully_authenticated,           'Not fully authenticated';
        ok $test_client->is_verification_required(check_authentication_status => 1),
            'Verification required due to deposits on an unauthenticated MF account';
        ok $test_client->needs_poi_verification, 'POI is needed for unauthenticated MLT account after first deposit';
        ok $test_client->needs_poa_verification, 'POA is needed for unauthenticated MLT account after first deposit';

        $mocked_client->mock('has_deposits', sub { return 0 });
        ok !$test_client->is_verification_required(check_authentication_status => 1),
            'Verification not required for an unauthenticated MF account without deposits';
        ok !$test_client->needs_poi_verification, 'POI is not needed for unauthenticated MLT account without deposits';
        ok !$test_client->needs_poa_verification, 'POA is not needed for unauthenticated MLT account without deposits';

        $mocked_client->unmock_all;
        $mocked_user->unmock_all;
    };
};

subtest 'Sign up' => sub {
    subtest 'MX' => sub {
        my $test_client = BOM::User::Client->rnew(
            broker_code     => 'MX',
            residence       => 'gb',
            citizen         => 'gb',
            email           => 'nowthatsan@email.com',
            loginid         => 'MX235711',
            client_password => BOM::User::Password::hashpw('asdf12345'),
        );
        my $user = BOM::User->create(
            email          => 'nowthatsan3@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($test_client);
        $test_client->binary_user_id($user->id);

        $uploaded = {};
        ok !$test_client->status->age_verification,                                  'Not age verified';
        ok !$test_client->fully_authenticated,                                       'Not fully authenticated';
        ok $test_client->is_verification_required(check_authentication_status => 1), 'Unauthenticated MX account needs verification';
        ok $test_client->needs_poi_verification,                                     'POI is needed for unauthenticated MX account without deposits';
        ok $test_client->needs_poa_verification,                                     'POA is needed for unauthenticated MX account without deposits';
    };
};

subtest 'Onfido status' => sub {
    my $test_client = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'br',
        citizen     => 'br',
        email       => 'onfido-status@email.com',
        loginid     => 'CR1317189'
    );
    my $user = BOM::User->create(
        email          => 'nowthatsan8@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($test_client);
    $test_client->binary_user_id($user->id);

    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    my $mocked_config = Test::MockModule->new('BOM::Config::Onfido');
    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    my $mocked_status = Test::MockModule->new('BOM::User::Client::Status');
    my $age_verification;

    $mocked_status->mock(
        'age_verification',
        sub {
            return {
                staff_name         => 'system',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss,
                reason             => $age_verification->{reason} // 'another one'
                }
                if $age_verification;

            return undef;
        });

    # backtest to prove that the onfido country supported status does not change the results!
    my $is_supported_country;
    $mocked_config->mock(
        'is_country_supported',
        sub {
            return $is_supported_country;
        });

    my ($onfido_document_status, $onfido_sub_result, $onfido_check_result);
    $mocked_onfido->mock(
        'get_latest_check',
        sub {
            return {
                report_document_status     => $onfido_document_status,
                report_document_sub_result => $onfido_sub_result,
                user_check                 => {
                    result => $onfido_check_result,
                },
            };
        });

    my $docs;
    my $is_document_expiry_check_required;

    my $mocked_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    $mocked_documents->mock(
        'uploaded',
        sub {
            return {
                onfido => {
                    defined $docs ? $docs->%* : (),
                    documents => {},
                }};
        });
    $mocked_client->mock(
        'is_document_expiry_check_required',
        sub {
            return $is_document_expiry_check_required;
        });
    $mocked_client->mock(
        'latest_poi_by',
        sub {
            return 'onfido';
        });

    my $tests = [{
            is_supported_country => 0,
            status               => 'none'
        },
        {
            # note this beautiful status equivalence when all variables are nullified
            is_supported_country => 1,
            status               => 'none'
        },
        {
            is_supported_country   => 1,
            onfido_document_status => 'in_progress',
            status                 => 'pending'
        },
        {
            is_supported_country   => 1,
            onfido_document_status => 'awaiting_applicant',
            status                 => 'pending'
        },
        {
            is_supported_country              => 1,
            is_document_expiry_check_required => 1,
            onfido_document_status            => 'complete',
            onfido_check_result               => 'clear',
            docs                              => {
                is_expired => 1,
            },
            status => 'expired'
        },
        {
            is_supported_country   => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'clear',
            docs                   => {
                is_expired => 0,
            },
            status           => 'verified',
            age_verification => {
                reason => 'onfido - age verified',
            },
        },
        {
            is_supported_country   => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'clear',
            docs                   => {
                is_expired => 0,
            },
            status           => 'rejected',
            age_verification => {
                reason => 'idv - age verified',
            },
        },
        {
            is_supported_country   => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'suspected',
            status                 => 'suspected'
        },
        {
            is_supported_country   => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'suspected',
            status                 => 'suspected'
        },
        {
            is_supported_country   => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'rejected',
            status                 => 'rejected'
        },
        {
            is_supported_country   => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'caution',
            status                 => 'rejected'
        },
        {
            is_supported_country   => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'clear',
            status                 => 'rejected'
        },
        {
            is_supported_country   => 1,
            pending_flag           => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'clear',
            status                 => 'pending'
        },
        {
            is_supported_country   => 1,
            pending_flag           => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'clear',
            docs                   => {
                is_expired => 0,
            },
            status => 'pending'
        },
        # unsupported countries backtest
        {
            is_supported_country   => 0,
            onfido_document_status => 'in_progress',
            status                 => 'none'
        },
        {
            is_supported_country   => 0,
            onfido_document_status => 'awaiting_applicant',
            status                 => 'none'
        },
        {
            is_supported_country              => 0,
            is_document_expiry_check_required => 1,
            onfido_document_status            => 'complete',
            onfido_check_result               => 'clear',
            docs                              => {
                is_expired => 1,
            },
            status => 'expired'
        },
        {
            is_supported_country   => 0,
            onfido_document_status => 'complete',
            onfido_check_result    => 'clear',
            docs                   => {
                is_expired => 0,
            },
            status           => 'verified',
            age_verification => {
                reason => 'onfido - age verified',
            },
        },
        {
            is_supported_country   => 0,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'suspected',
            status                 => 'suspected'
        },
        {
            is_supported_country   => 0,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'suspected',
            status                 => 'suspected'
        },
        {
            is_supported_country   => 0,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'rejected',
            status                 => 'rejected'
        },
        {
            is_supported_country   => 0,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'caution',
            status                 => 'rejected'
        },
        {
            is_supported_country   => 0,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'clear',
            status                 => 'rejected'
        },
        {
            is_supported_country   => 0,
            pending_flag           => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'consider',
            onfido_sub_result      => 'clear',
            status                 => 'none'
        },
        {
            is_supported_country   => 0,
            pending_flag           => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'clear',
            docs                   => {
                is_expired => 0,
            },
            status => 'none'
        },
        {
            is_supported_country => 1,
            status               => 'rejected',
            incr                 => 1,
        },
    ];

    for my $test ($tests->@*) {
        my $pending_key = +BOM::User::Onfido::ONFIDO_REQUEST_PENDING_PREFIX . $user->id;
        my $redis       = BOM::Config::Redis::redis_events();
        my $pending_flag;
        my $status;
        my $incr;

        (
            $is_supported_country, $onfido_document_status, $onfido_check_result,               $onfido_sub_result,
            $docs,                 $status,                 $is_document_expiry_check_required, $pending_flag,
            $age_verification,     $incr
            )
            = @{$test}{
            qw/is_supported_country onfido_document_status onfido_check_result onfido_sub_result docs status is_document_expiry_check_required pending_flag age_verification incr/
            };

        if ($incr) {
            $redis->incr(+BOM::User::Onfido::ONFIDO_REQUEST_PER_USER_PREFIX . $user->id);
        }

        if ($pending_flag) {
            $redis->set($pending_key, 1);
        } else {
            $redis->del($pending_key);
        }

        is $test_client->get_onfido_status, $status, "Got the expected status=$status";
    }

    $mocked_onfido->unmock_all;
    $mocked_config->unmock_all;
    $mocked_client->unmock_all;
    $mocked_documents->unmock_all;
    $mocked_status->unmock_all;
};

subtest 'Manual POI status' => sub {
    my $test_client = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'br',
        citizen     => 'br',
        email       => 'manual-poi-status@email.com',
        loginid     => 'CR1317184'
    );
    my $user = BOM::User->create(
        email          => 'nowthatsan9@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($test_client);
    $test_client->binary_user_id($user->id);

    my $mocked_config = Test::MockModule->new('BOM::Config::Onfido');
    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    my $mocked_status = Test::MockModule->new('BOM::User::Client::Status');
    my $age_verification;
    my $is_document_expiry_check_required;
    my $idv;
    my $onfido;
    my $ignore_age_verification;

    $mocked_client->mock(
        'is_document_expiry_check_required',
        sub {
            return $is_document_expiry_check_required;
        });
    $mocked_client->mock(
        'get_idv_status',
        sub {
            return $idv;
        });
    $mocked_client->mock(
        'get_onfido_status',
        sub {
            return $onfido;
        });
    $mocked_client->mock(
        'ignore_age_verification',
        sub {
            return $ignore_age_verification;
        });

    $mocked_status->mock(
        'age_verification',
        sub {
            return {
                staff_name         => 'staff',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            } if $age_verification;

            return undef;
        });

    my ($is_expired, $is_pending, $documents);
    my $mocked_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    $mocked_documents->mock(
        'uploaded',
        sub {
            return {
                proof_of_identity => {
                    is_expired => $is_expired,
                    is_pending => $is_pending,
                    documents  => $documents,
                },
            };
        });

    my $verified;
    $mocked_documents->mock(
        'verified',
        sub {
            return $verified;
        });

    my $tests = [{
            status => 'none',
            onfido => 'none',
            idv    => 'none',
        },
        {
            is_pending => 1,
            documents  => {
                test => {},
            },
            onfido => 'none',
            idv    => 'none',
            status => 'pending',
        },
        {
            is_expired => 1,
            onfido     => 'none',
            idv        => 'none',
            status     => 'expired',
            documents  => {
                test => {},
            },
            is_document_expiry_check_required => 1,
        },
        {
            age_verification => 1,
            onfido           => 'none',
            idv              => 'none',
            status           => 'verified',
            documents        => {
                test => {},
            },
        },
        {
            status    => 'none',
            onfido    => 'pending',
            idv       => 'none',
            documents => {},
        },
        {
            status    => 'none',
            onfido    => 'none',
            idv       => 'pending',
            documents => {},
        },
        {
            status    => 'verified',
            onfido    => 'none',
            idv       => 'none',
            documents => {
                test => {},
            },
            verified                => 0,
            age_verification        => 1,
            ignore_age_verification => 0,
        },
        {
            status    => 'pending',
            onfido    => 'none',
            idv       => 'none',
            documents => {
                test => {},
            },
            verified                => 1,
            age_verification        => 1,
            ignore_age_verification => 1,
        },
        {
            status    => 'pending',
            onfido    => 'none',
            idv       => 'none',
            documents => {
                test => {},
            },
            verified                => 1,
            age_verification        => 0,
            ignore_age_verification => 0,
        }
        ],
        ;

    for my $test ($tests->@*) {
        my $status;

        (
            $is_expired, $is_pending, $age_verification, $status,                  $is_document_expiry_check_required,
            $onfido,     $idv,        $documents,        $ignore_age_verification, $verified
            )
            = @{$test}
            {qw/is_expired is_pending age_verification status is_document_expiry_check_required onfido idv documents ignore_age_verification verified/
            };

        is $test_client->get_manual_poi_status, $status, "Got the expected status=$status";
    }

    $mocked_status->unmock_all;
    $mocked_config->unmock_all;
    $mocked_client->unmock_all;
    $mocked_documents->unmock_all;
};

subtest 'IDV status' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'br',
        citizen     => 'br',
        email       => 'idv-poi-status@email.com',
        loginid     => 'CR191003'
    });
    my $user = BOM::User->create(
        email          => 'idv-poi-status@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($client);
    $client->binary_user_id($user->id);
    $client->save;

    my $tests = [{
            document => {
                issuing_country => 'br',
                document_number => 'BR-001',
                document_type   => 'national_identity_card',
                status          => 'verified',
            },
            expected => 'verified'
        },
        {
            document => {
                issuing_country => 'br',
                document_number => 'BR-001',
                document_type   => 'national_identity_card',
                status          => 'refuted',
            },
            expected => 'rejected'
        },
        {
            document => {
                issuing_country => 'br',
                document_number => 'BR-001',
                document_type   => 'national_identity_card',
                status          => 'failed',
            },
            expected => 'rejected'
        },
        {
            document => {
                issuing_country => 'br',
                document_number => 'BR-001',
                document_type   => 'national_identity_card',
                status          => 'pending',
            },
            expected => 'pending'
        },
        {
            document => {
                issuing_country          => 'br',
                document_number          => 'BR-001',
                document_type            => 'national_identity_card',
                status                   => 'verified',
                document_expiration_date => Date::Utility->new()->_minus_years(1),
            },
            expected => 'expired'
        },
        {
            document => {
                issuing_country          => 'br',
                document_number          => 'BR-001',
                document_type            => 'national_identity_card',
                status                   => 'verified',
                document_expiration_date => Date::Utility->new()->_plus_years(1),
            },
            expected => 'verified'
        },
        {
            document => undef,
            expected => 'none'
        }];

    for my $test ($tests->@*) {
        my ($doc_data, $expected) = @{$test}{qw/document expected/};

        my $doc_mock = Test::MockModule->new('BOM::User::IdentityVerification');
        $doc_mock->mock(
            'get_last_updated_document',
            sub {
                return $doc_data;
            });

        is $client->get_idv_status, $expected, "Expected status: $expected";
    }
};

subtest 'POI attempts' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $mocked_docs = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    my $manual_latest;

    $mocked_docs->mock(
        'latest',
        sub {
            my ($self) = @_;
            my $latest = $manual_latest;

            $self->_clear_latest;

            return $latest;
        });

    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    my $manual_status;
    $mocked_client->mock(
        'get_manual_poi_status',
        sub {
            return $manual_status;
        });

    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    my $onfido_list;

    $mocked_onfido->mock(
        'get_onfido_checks',
        sub {
            return $onfido_list;
        });

    my $mocked_idv = Test::MockModule->new('BOM::User::IdentityVerification');
    my $idv_list;

    $mocked_idv->mock(
        'get_document_check_list',
        sub {
            return $idv_list;
        });

    my $now    = Date::Utility->new();
    my $before = Date::Utility->new()->_minus_years(1);
    my $after  = Date::Utility->new()->_plus_years(1);

    my $tests = [{
            title   => 'No attempts',
            onfido  => undef,
            idv     => undef,
            results => [],
        },
        {
            title  => 'Only Onfido in_progress',
            onfido => [{
                    status     => 'in_progress',
                    result     => undef,
                    id         => 'onfido-test-1',
                    created_at => $now->datetime_yyyymmdd_hhmmss,
                }
            ],
            idv     => undef,
            results => [{
                    service      => 'onfido',
                    status       => 'pending',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 'onfido-test-1',
                    timestamp    => re('\d+'),
                }
            ],
        },
        {
            title  => 'Only Onfido consider',
            onfido => [{
                    status       => 'complete',
                    result       => 'consider',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 'onfido-test-2',
                    created_at   => $now->datetime_yyyymmdd_hhmmss,
                }
            ],
            idv     => undef,
            results => [{
                    service      => 'onfido',
                    status       => 'rejected',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 'onfido-test-2',
                    timestamp    => re('\d+'),
                }
            ],
        },
        {
            title  => 'Only Onfido clear',
            onfido => [{
                    status       => 'complete',
                    result       => 'clear',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 'onfido-test-3',
                    timestamp    => $now->datetime_yyyymmdd_hhmmss,
                }
            ],
            idv     => undef,
            results => [{
                    service      => 'onfido',
                    status       => 'verified',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 'onfido-test-3',
                    timestamp    => re('\d+'),
                }
            ],
        },
        {
            title  => 'Only IDV pending',
            onfido => undef,
            idv    => [{
                    issuing_country => 'ng',
                    status          => 'pending',
                    id              => 1,
                    submitted_at    => $now->datetime_yyyymmdd_hhmmss,
                    document_type   => 'national_id',
                }
            ],
            results => [{
                    service       => 'idv',
                    status        => 'pending',
                    country_code  => 'ng',
                    id            => '1',
                    timestamp     => re('\d+'),
                    document_type => 'national_id',
                }
            ],
        },
        {
            title  => 'Only IDV failed',
            onfido => undef,
            idv    => [{
                    issuing_country => 'za',
                    status          => 'failed',
                    id              => 2,
                    submitted_at    => $now->datetime_yyyymmdd_hhmmss,
                    document_type   => 'national_id',
                }
            ],
            results => [{
                    service       => 'idv',
                    status        => 'rejected',
                    country_code  => 'za',
                    id            => '2',
                    timestamp     => re('\d+'),
                    document_type => 'national_id',
                }
            ],
        },
        {
            title  => 'Only IDV refuted',
            onfido => undef,
            idv    => [{
                    issuing_country => 'gh',
                    status          => 'refuted',
                    id              => 3,
                    submitted_at    => $now->datetime_yyyymmdd_hhmmss,
                    document_type   => 'national_id',
                }
            ],
            results => [{
                    service       => 'idv',
                    status        => 'rejected',
                    country_code  => 'gh',
                    id            => '3',
                    timestamp     => re('\d+'),
                    document_type => 'national_id',
                }
            ],
        },
        {
            title  => 'Only IDV verified',
            onfido => undef,
            idv    => [{
                    issuing_country => 'ke',
                    status          => 'verified',
                    id              => 4,
                    submitted_at    => $now->datetime_yyyymmdd_hhmmss,
                    document_type   => 'national_id',
                }
            ],
            results => [{
                    service       => 'idv',
                    status        => 'verified',
                    country_code  => 'ke',
                    id            => '4',
                    timestamp     => re('\d+'),
                    document_type => 'national_id',
                }
            ],
        },
        {
            title  => 'Onfido should be the first in the list',
            onfido => undef,
            onfido => [{
                    status     => 'in_progress',
                    result     => undef,
                    id         => 'onfido-test-1',
                    created_at => $after->datetime_yyyymmdd_hhmmss,
                }
            ],
            idv => [{
                    issuing_country => 'ke',
                    status          => 'verified',
                    id              => 4,
                    submitted_at    => $before->datetime_yyyymmdd_hhmmss,
                    document_type   => 'national_id',
                }
            ],
            results => [{
                    service      => 'onfido',
                    status       => 'pending',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 'onfido-test-1',
                    timestamp    => re('\d+'),
                },
                {
                    service       => 'idv',
                    status        => 'verified',
                    country_code  => 'ke',
                    id            => '4',
                    timestamp     => re('\d+'),
                    document_type => 'national_id',
                }
            ],
        },
        {
            title  => 'IDV should be the first in the list',
            onfido => [{
                    status     => 'in_progress',
                    result     => undef,
                    id         => 'onfido-test-1',
                    created_at => $before->datetime_yyyymmdd_hhmmss,
                }
            ],
            idv => [{
                    issuing_country => 'ke',
                    status          => 'verified',
                    id              => 4,
                    submitted_at    => $after->datetime_yyyymmdd_hhmmss,
                    document_type   => 'national_id',
                }
            ],
            results => [{
                    service       => 'idv',
                    status        => 'verified',
                    country_code  => 'ke',
                    id            => '4',
                    timestamp     => re('\d+'),
                    document_type => 'national_id',
                },
                {
                    service      => 'onfido',
                    status       => 'pending',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 'onfido-test-1',
                    timestamp    => re('\d+'),
                }
            ],
        },

        {
            title  => 'Only Manual pending',
            manual => {
                status      => 'pending',
                origin      => 'bo',
                id          => 1,
                uploaded_at => $now->datetime_yyyymmdd_hhmmss,
            },
            onfido  => undef,
            idv     => undef,
            results => [{
                    service      => 'manual',
                    status       => 'pending',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 1,
                    timestamp    => re('\d+'),
                }
            ],
        },
        {
            title  => 'Only Manual rejected',
            manual => {
                status      => 'rejected',
                origin      => 'bo',
                id          => 1,
                uploaded_at => $now->datetime_yyyymmdd_hhmmss,
            },
            onfido  => undef,
            idv     => undef,
            results => [{
                    service      => 'manual',
                    status       => 'rejected',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 1,
                    timestamp    => re('\d+'),
                }
            ],
        },
        {
            title  => 'Only Manual verified',
            manual => {
                status      => 'verified',
                origin      => 'bo',
                id          => 1,
                uploaded_at => $now->datetime_yyyymmdd_hhmmss,
            },
            onfido  => undef,
            idv     => undef,
            results => [{
                    service      => 'manual',
                    status       => 'verified',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 1,
                    timestamp    => re('\d+'),
                }
            ],
        },
        {
            title  => 'Only Manual expired',
            manual => {
                status      => 'expired',
                origin      => 'bo',
                id          => 1,
                uploaded_at => $now->datetime_yyyymmdd_hhmmss,
            },
            onfido  => undef,
            idv     => undef,
            results => [{
                    service      => 'manual',
                    status       => 'expired',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 1,
                    timestamp    => re('\d+'),
                }
            ],
        },

        {
            title  => 'Manual should be the first in the list',
            onfido => [{
                    status     => 'in_progress',
                    result     => undef,
                    id         => 'onfido-test-1',
                    created_at => $before->_minus_years(1)->datetime_yyyymmdd_hhmmss,
                }
            ],
            manual => {
                status      => 'pending',
                origin      => 'bo',
                id          => 1,
                uploaded_at => $after->datetime_yyyymmdd_hhmmss,
            },
            idv => [{
                    issuing_country => 'ke',
                    status          => 'verified',
                    id              => 4,
                    submitted_at    => $before->datetime_yyyymmdd_hhmmss,
                    document_type   => 'national_id',
                }
            ],
            results => [{
                    service      => 'manual',
                    status       => 'pending',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 1,
                    timestamp    => re('\d+'),
                },
                {
                    service       => 'idv',
                    status        => 'verified',
                    country_code  => 'ke',
                    id            => '4',
                    timestamp     => re('\d+'),
                    document_type => 'national_id',
                },
                {
                    service      => 'onfido',
                    status       => 'pending',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 'onfido-test-1',
                    timestamp    => re('\d+'),
                }
            ],
        },
    ];

    for my $test ($tests->@*) {
        my ($title, $onfido, $idv, $results, $manual) = @{$test}{qw/title onfido idv results manual/};

        $onfido_list = $onfido;
        $idv_list    = $idv;

        $manual_status = $manual ? delete $manual->{status} : undef;
        $manual_latest = $manual;

        subtest $title => sub {
            cmp_deeply $client->poi_attempts,
                {
                history => $results,
                count   => scalar $results->@*,
                latest  => $results->[0],
                },
                'Expected POI attempts';
        };
    }

    $mocked_onfido->unmock_all;
    $mocked_idv->unmock_all;
    $mocked_client->unmock_all;
    $mocked_docs->unmock_all;
};

subtest 'Jurisdiction POI status' => sub {
    my $test_client = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'br',
        citizen     => 'br',
        email       => 'jurisdiction-poi-status@email.com',
        loginid     => 'CR1317184'
    );
    my $user = BOM::User->create(
        email          => 'jurisdiction-poi-status@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($test_client);
    $test_client->binary_user_id($user->id);

    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    my $mocked_status = Test::MockModule->new('BOM::User::Client::Status');
    my ($age_verification, $manual, $idv, $onfido, $landing_company);

    $mocked_client->mock(
        get_manual_poi_status => sub { return $manual },
        get_idv_status        => sub { return $idv },
        get_onfido_status     => sub { return $onfido },
        is_idv_validated      => sub { return $idv eq 'verified' ? 1 : 0 },
    );

    $mocked_status->mock(
        'age_verification',
        sub {
            return {
                staff_name         => 'system',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            } if $age_verification;

            return undef;
        });

    my $tests = [{
            name             => 'SVG: no document, not age verified => none',
            status           => 'none',
            onfido           => 'none',
            idv              => 'none',
            manual           => 'none',
            age_verification => undef,
            landing_company  => 'svg',
        },
        {
            name             => 'SVG: IDV verified => verified',
            status           => 'verified',
            onfido           => 'none',
            idv              => 'verified',
            manual           => 'none',
            age_verification => {
                staff_name         => 'system',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'svg',
        },
        {
            name             => 'SVG: Onfido verifed => verified',
            status           => 'verified',
            onfido           => 'verified',
            idv              => 'none',
            manual           => 'none',
            age_verification => {
                staff_name         => 'system',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'svg',
        },
        {
            name             => 'SVG: manualy verifed => verified',
            status           => 'verified',
            onfido           => 'none',
            idv              => 'none',
            manual           => 'verified',
            age_verification => {
                staff_name         => 'staff',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'svg',
        },
        {
            name             => 'SVG: no document, manually verifed=> verified',
            status           => 'verified',
            onfido           => 'none',
            idv              => 'none',
            manual           => 'none',
            age_verification => {
                staff_name         => 'staff',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'svg',
        },
        {
            name             => 'Maltainvest: no document, not age verified => none',
            status           => 'none',
            onfido           => 'none',
            idv              => 'none',
            manual           => 'none',
            age_verification => undef,
            landing_company  => 'svg',
        },
        {
            name             => 'Maltainvest: IDV verified => none',
            status           => 'none',
            onfido           => 'none',
            idv              => 'verified',
            manual           => 'none',
            age_verification => {
                staff_name         => 'system',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'maltainvest',
        },
        {
            name             => 'Maltainvest: Onfido verifed => verified',
            status           => 'verified',
            onfido           => 'verified',
            idv              => 'none',
            manual           => 'none',
            age_verification => {
                staff_name         => 'system',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'maltainvest',
        },
        {
            name             => 'Maltainvest: manualy verifed => verified',
            status           => 'verified',
            onfido           => 'none',
            idv              => 'none',
            manual           => 'verified',
            age_verification => {
                staff_name         => 'staff',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'maltainvest',
        },
        {
            name             => 'Maltainvest: no document, manually verifed=> verified',
            status           => 'verified',
            onfido           => 'none',
            idv              => 'none',
            manual           => 'none',
            age_verification => {
                staff_name         => 'staff',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'maltainvest',
        },
        {
            name             => 'Maltainvest: no document, not age verified => none',
            status           => 'none',
            onfido           => 'none',
            idv              => 'none',
            manual           => 'none',
            age_verification => undef,
            landing_company  => 'maltainvest',
        },
        {
            name             => 'Vanuatu: IDV verified => none',
            status           => 'verified',
            onfido           => 'none',
            idv              => 'verified',
            manual           => 'none',
            age_verification => {
                staff_name         => 'system',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'vanuatu',
        },
        {
            name             => 'Vanuatu: Onfido verifed => verified',
            status           => 'verified',
            onfido           => 'verified',
            idv              => 'none',
            manual           => 'none',
            age_verification => {
                staff_name         => 'system',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'vanuatu',
        },
        {
            name             => 'Vanuatu: manualy verifed => verified',
            status           => 'verified',
            onfido           => 'none',
            idv              => 'none',
            manual           => 'verified',
            age_verification => {
                staff_name         => 'staff',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'vanuatu',
        },
        {
            name             => 'Vanuatu: no document, manually verifed=> verified',
            status           => 'verified',
            onfido           => 'none',
            idv              => 'none',
            manual           => 'none',
            age_verification => {
                staff_name         => 'staff',
                last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
            },
            landing_company => 'vanuatu',
        },
        {
            name             => 'Vanuatu: no document, not age verified => none',
            status           => 'none',
            onfido           => 'none',
            idv              => 'none',
            manual           => 'none',
            age_verification => undef,
            landing_company  => 'vanuatu',
        },
    ];

    for my $test ($tests->@*) {
        my ($name, $status);

        ($name, $age_verification, $status, $manual, $onfido, $idv, $landing_company) =
            @{$test}{qw/name age_verification status manual onfido idv landing_company/};

        is $test_client->get_poi_status({landing_company => $landing_company}), $status, $name;
    }

    $mocked_status->unmock_all;
    $mocked_client->unmock_all;
};

subtest 'fully auth at BO scenario' => sub {
    my @latest_poi_by;
    my $is_expired = 0;
    my $is_pending = 0;
    my $fully_authenticated;
    my $age_verification;
    my $is_document_expiry_check_required;
    my $documents = {};

    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    $mocked_client->mock('latest_poi_by',                     sub { return @latest_poi_by });
    $mocked_client->mock('fully_authenticated',               sub { return $fully_authenticated });
    $mocked_client->mock('is_document_expiry_check_required', sub { return $is_document_expiry_check_required });

    my $mocked_status = Test::MockModule->new('BOM::User::Client::Status');
    $mocked_status->mock('age_verification', sub { return $age_verification });

    my $mocked_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    $mocked_documents->mock(
        'uploaded',
        sub {
            return {
                proof_of_identity => {
                    is_expired => $is_expired,
                    is_pending => $is_pending,
                    documents  => $documents,
                },
            };
        });

    my $test_client = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'br',
        citizen     => 'br',
        email       => 'fa-BO-status@email.com',
        loginid     => 'CR1317184'
    );
    my $user = BOM::User->create(
        email          => 'fa-BO-status@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($test_client);
    $test_client->binary_user_id($user->id);

    is $test_client->get_poi_status,        'none', 'None status';
    is $test_client->get_manual_poi_status, 'none', 'None status';

    # fake some pending doc

    $documents     = {test => {}};
    $is_pending    = 1;
    @latest_poi_by = ('manual');

    is $test_client->get_poi_status,        'pending', 'Pending status';
    is $test_client->get_manual_poi_status, 'pending', 'Pending status';

    # fully auth at BO
    # note when fully auth at BO the age verified status is not set by staff (maybe a trigger disrupting?)

    $documents           = $expirable_doc;
    $is_pending          = 0;
    $fully_authenticated = 1;
    $age_verification    = {
        staff_name => 'system',
        reason     => 'why not'
    };
    @latest_poi_by = ('manual');

    is $test_client->get_poi_status,        'verified', 'Verified status';
    is $test_client->get_manual_poi_status, 'verified', 'Verified status';

    # important to test!
    # expired flow
    $documents                         = $expirable_doc;
    $is_expired                        = 1;
    $is_document_expiry_check_required = 1;
    $fully_authenticated               = 1;
    $age_verification                  = {
        staff_name => 'system',
        reason     => 'why not'
    };
    @latest_poi_by = ('manual');

    is $test_client->get_poi_status,        'expired', 'Expired status';
    is $test_client->get_manual_poi_status, 'expired', 'Expired status';

    # the client uploads a non expired document
    $documents                         = $expirable_doc;
    $is_expired                        = 1;
    $is_pending                        = 1;
    $is_document_expiry_check_required = 1;
    $fully_authenticated               = 1;
    $age_verification                  = {
        staff_name => 'system',
        reason     => 'why not'
    };
    @latest_poi_by = ('manual');

    is $test_client->get_poi_status,        'pending', 'Pending status';
    is $test_client->get_manual_poi_status, 'pending', 'Pending status';

    # document is verified
    $documents                         = $expirable_doc;
    $is_expired                        = 0;
    $is_pending                        = 0;
    $is_document_expiry_check_required = 1;
    $fully_authenticated               = 1;
    $age_verification                  = {
        staff_name => 'system',
        reason     => 'why not'
    };
    @latest_poi_by = ('manual');

    is $test_client->get_poi_status,        'verified', 'Verified status';
    is $test_client->get_manual_poi_status, 'verified', 'Verified status';

    $mocked_documents->unmock_all;
    $mocked_client->unmock_all;
    $mocked_status->unmock_all;
};

subtest 'poi status by jurisdiction' => sub {
    my $client = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'br',
        citizen     => 'br',
        email       => 'poi+jurisdction@email.com',
        loginid     => 'CR1317184'
    );
    my $user = BOM::User->create(
        email          => 'poi+jurisdction@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($client);
    $client->binary_user_id($user->id);

    my $tests = [{
            ignore => 1,
            status => 'none',
            lc     => 'bvi',
            test   => 'lc=bvi ignore age verification'
        },
        {
            ignore => 1,
            status => 'none',
            lc     => 'labuan',
            test   => 'lc=labuan ignore age verification'
        },
        {
            ignore => 1,
            status => 'none',
            lc     => 'vanuatu',
            test   => 'lc=vanuatu ignore age verification'
        },
        {
            ignore => 1,
            status => 'none',
            lc     => 'maltainvest',
            test   => 'lc=maltainvest ignore age verification'
        },
    ];

    for my $status (qw/verified pending suspected rejected expired none/) {
        for my $lc (qw/labuan maltainvest vanuatu bvi/) {
            my $idv_ignore;
            $idv_ignore = 1 if $lc eq 'maltainvest';

            for my $provider (qw/onfido idv manual/) {
                my $expected = $status;
                $expected = 'none' if $idv_ignore && $provider eq 'idv';

                push $tests->@*,
                    {
                    ignore    => 0,
                    $provider => $status,
                    status    => $expected,
                    lc        => $lc,
                    test      => "lc=$lc $provider=$status expected=$expected"
                    };

                push $tests->@*,
                    {
                    ignore        => 0,
                    $provider     => $status,
                    status        => 'rejected',
                    name_mismatch => 1,
                    lc            => $lc,
                    test          => "lc=$lc $provider=$status expected=rejected (name mismatch)"
                    }
                    if $expected eq 'none' || $expected eq 'expired';

                push $tests->@*,
                    {
                    ignore       => 0,
                    $provider    => $status,
                    status       => 'rejected',
                    dob_mismatch => 1,
                    lc           => $lc,
                    test         => "lc=$lc $provider=$status expected=rejected (dob mismatch)"
                    }
                    if $expected eq 'none' || $expected eq 'expired';
            }
        }
    }

    my $status_mock = Test::MockModule->new(ref($client->status));
    my $name_mismatch;
    $status_mock->mock(
        'poi_name_mismatch',
        sub {
            $name_mismatch;
        });
    my $dob_mismatch;
    $status_mock->mock(
        'poi_dob_mismatch',
        sub {
            $dob_mismatch;
        });

    my $cli_mock = Test::MockModule->new(ref($client));
    my $ignore;
    my $manual;
    my $idv;
    my $onfido;

    $cli_mock->mock(
        'ignore_age_verification',
        sub {
            return $ignore;
        });

    $cli_mock->mock(
        'get_manual_poi_status',
        sub {
            return $manual;
        });

    $cli_mock->mock(
        'get_idv_status',
        sub {
            return $idv;
        });

    $cli_mock->mock(
        'get_onfido_status',
        sub {
            return $onfido;
        });

    my $test;
    my $status;
    my $lc;

    for my $test ($tests->@*) {
        ($test, $lc, $ignore, $manual, $idv, $onfido, $dob_mismatch, $name_mismatch, $status) =
            @{$test}{qw/test lc ignore manual idv onfido dob_mismatch name_mismatch status/};

        $onfido //= 'none';
        $idv    //= 'none';
        $manual //= 'none';

        is $client->get_poi_status_jurisdiction({landing_company => $lc}), $status, $test;
    }

    $cli_mock->unmock_all;
    $status_mock->unmock_all;
};

subtest 'ignore age verification' => sub {
    my $client = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'br',
        citizen     => 'br',
        email       => 'ignore+poi+status@email.com',
        loginid     => 'CR1317184'
    );
    my $user = BOM::User->create(
        email          => 'ignore+poi+status@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($client);
    $client->binary_user_id($user->id);

    my $cli_mock = Test::MockModule->new(ref($client));
    my $high_risk;
    my $idv_validated;

    $cli_mock->mock(
        'is_high_risk',
        sub {
            return $high_risk;
        });
    $cli_mock->mock(
        'is_idv_validated',
        sub {
            return $idv_validated;
        });

    $high_risk     = 0;
    $idv_validated = 0;

    for my $lc (qw/vanuatu maltainvest bvi labuan/, undef) {
        ok !$client->ignore_age_verification({landing_company => $lc}), 'Not high risk nor IDV validated';
    }

    $high_risk     = 1;
    $idv_validated = 0;

    for my $lc (qw/vanuatu maltainvest bvi labuan/, undef) {
        ok !$client->ignore_age_verification({landing_company => $lc}), 'Not IDV validated';
    }

    $high_risk     = 1;
    $idv_validated = 1;

    for my $lc (qw/vanuatu maltainvest bvi labuan/, undef) {
        my $str_lc = $lc // 'undef';
        ok $client->ignore_age_verification({landing_company => $lc}), "age verification is ignored on high risk lc=$str_lc";
    }

    $high_risk     = 0;
    $idv_validated = 1;

    for my $lc (qw/vanuatu maltainvest bvi labuan/, undef) {
        my $landing_company = LandingCompany::Registry->by_name($lc // $client->landing_company->short);
        my $str_lc          = $lc // 'undef';

        if (List::Util::none { $_ eq 'idv' } $landing_company->allowed_poi_providers->@*) {
            ok $client->ignore_age_verification({landing_company => $lc}), "age verification is ignored on low risk lc=$str_lc";
        } else {
            ok !$client->ignore_age_verification({landing_company => $lc}), "age verification is not ignored on low risk lc=$str_lc";
        }
    }
};

subtest 'Onfido status, under fully auth while having mismatch status' => sub {
    my $age_verification;
    my $mocked_status = Test::MockModule->new('BOM::User::Client::Status');
    $mocked_status->mock('age_verification', sub { return $age_verification; });

    my $fully_authenticated;
    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    $mocked_client->mock('fully_authenticated', sub { return $fully_authenticated });

    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    my ($onfido_document_status, $onfido_sub_result, $user_check_result);
    $mocked_onfido->mock(
        'get_latest_check',
        sub {
            return {
                user_check => {
                    result => $user_check_result,
                },
                report_document_status     => $onfido_document_status,
                report_document_sub_result => $onfido_sub_result,
            };
        });

    my $test_client = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'br',
        citizen     => 'br',
        email       => 'onfido_fa-BO2-status@email.com',
        loginid     => 'CR13179999'
    );
    my $user = BOM::User->create(
        email          => 'onfido_fa-BO2-status@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($test_client);
    $test_client->binary_user_id($user->id);

    $onfido_document_status = 'clear';
    $onfido_sub_result      = 'clear';
    $user_check_result      = 'clear';

    is $test_client->get_onfido_status, 'rejected', 'Even though all is clear without age verification, this is kept as rejected';

    $age_verification    = {reason => 'fully authenticated at bo'};
    $fully_authenticated = 1;

    is $test_client->get_onfido_status, 'rejected', 'verification at bo does not change onfido status';

    $age_verification    = {reason => 'onfido authenticated'};
    $fully_authenticated = 1;

    is $test_client->get_onfido_status, 'verified', 'had the verification been done by Onfido, the status would be verified';

};

done_testing();
