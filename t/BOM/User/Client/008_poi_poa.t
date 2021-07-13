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

subtest 'get_poa_status' => sub {
    subtest 'Unregulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

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
    };

    subtest 'Regulated account' => sub {
        my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });

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

    subtest 'Unregulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        subtest 'POI status none' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => {},
                }};

            is $test_client_cr->get_poi_status, 'none', 'Client POI status is none';
            $mocked_client->unmock_all;
        };

        subtest 'POI status expired' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    documents  => {},
                }};

            is $test_client_cr->get_poi_status, 'expired', 'Client POI status is expired';
            $mocked_client->unmock_all;
        };

        subtest 'POI status pending' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => {},
                }};

            $onfido_document_status = 'in_progress';
            is $test_client_cr->get_poi_status, 'pending', 'Client POI status is pending';
            $mocked_client->unmock_all;

            subtest 'pending is above everything' => sub {
                $mocked_client->mock('fully_authenticated', sub { return 0 });
                $uploaded = {
                    proof_of_identity => {
                        is_expired => 1,
                        documents  => {},
                    }};
                $onfido_document_status = 'in_progress';
                is $test_client_cr->get_poi_status, 'pending', 'Client POI status is still expired';
                $mocked_client->unmock_all;
            };
        };

        subtest 'POI status is pending' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_identity => {
                    is_pending => 1,
                    documents  => {},
                }};

            $onfido_document_status = undef;
            is $test_client_cr->get_poi_status, 'pending', 'Client POI status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POI documents expired but onfido status in_progress' => sub {
            $onfido_document_status = 'in_progress';
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    documents  => {},
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

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => {},
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

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => {},
                }};

            is $test_client_cr->get_poi_status, 'suspected', 'Client POI status is suspected';
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

            is $test_client_cr->get_poi_status, 'verified', 'Client POI status is verified';
            $mocked_client->unmock_all;
        };

        subtest 'POI status rejected - fully authenticated or age verified' => sub {
            $test_client_cr->status->clear_age_verification;
            my $authenticated = 1;
            $mocked_client->mock('fully_authenticated', sub { return $authenticated });

            my $authenticated_test_scenarios = sub {
                $uploaded = {
                    proof_of_identity => {
                        is_expired => 0,
                        documents  => {},
                    }};
                $onfido_document_status = 'complete';
                $onfido_sub_result      = 'rejected';
                is $test_client_cr->get_poi_status, 'verified',
                    'POI status of an authenticated client is <verified> - even with rejected onfido check';

                $onfido_document_status = 'complete';
                $onfido_sub_result      = 'clear';
                $uploaded               = {
                    proof_of_identity => {
                        is_expired => 1,
                        documents  => {},
                    }};
                is $test_client_cr->get_poi_status, 'expired', 'POI status of an authenticated client is <expired> - if expiry check is required';

                $onfido_document_status = 'complete';
                $onfido_sub_result      = 'rejected';
                $uploaded               = {
                    proof_of_identity => {
                        is_expired => 1,
                        documents  => {},
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
    };

    subtest 'Regulated account' => sub {
        my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
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

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        subtest 'Not needed' => sub {
            $mocked_client->mock('get_poa_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });

            $uploaded = {
                proof_of_address => {
                    documents => 'something',
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
                    documents => 'something',
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

        my $mocked_client = Test::MockModule->new(ref($test_client_mf));
        subtest 'Not needed' => sub {
            $mocked_client->mock('get_poa_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $uploaded = {
                proof_of_address => {
                    documents => 'something',
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

            ok $test_client_mf->needs_poa_verification, 'POA is needed due not fully authenticated and authentication needed';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $uploaded = {
                proof_of_address => {
                    documents => 'something',
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

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        my $mocked_status = Test::MockModule->new(ref($test_client_cr->status));

        subtest 'Needed when verified' => sub {
            $mocked_client->mock('get_poi_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $mocked_status->mock('age_verification',    sub { return 1 });
            $uploaded = {
                proof_of_address => {
                    documents => 'something',
                }};
            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
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
            $mocked_status->mock('age_verification',    sub { return 1 });
            $uploaded = {
                proof_of_identity => {
                    documents => 'something',
                }};
            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });

            ok !$test_client_cr->needs_poi_verification, 'POI is not needed';

            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $uploaded = {
                proof_of_identity => {
                    documents => 'something',
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
                    documents => 'something',
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

        my $mocked_client = Test::MockModule->new(ref($test_client_mf));
        my $mocked_status = Test::MockModule->new(ref($test_client_mf->status));
        subtest 'Not needed' => sub {
            $mocked_client->mock('get_poi_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $mocked_status->mock('age_verification',    sub { return 1 });
            $uploaded = {
                proof_of_address => {
                    documents => 'something',
                }};
            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });

            ok !$test_client_mf->needs_poi_verification, 'POI is not needed';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $uploaded = {
                proof_of_identity => {
                    documents => 'something',
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
                    documents => 'something',
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
};

subtest 'is_document_expiry_check_required' => sub {
    subtest 'Unregulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        $mocked_client->mock('fully_authenticated', sub { return 0 });
        ok !$test_client_cr->landing_company->documents_expiration_check_required, 'Unregulated landing company does require expiration check';
        ok $test_client_cr->aml_risk_classification ne 'high', 'Account aml risk is not high';
        # Now we are sure execution flow reaches our new fully_authenticated condition
        ok !$test_client_cr->fully_authenticated,               'Account is not fully authenticated';
        ok !$test_client_cr->is_document_expiry_check_required, "Not fully authenticated CR account doesn't have to check documents expiry";

        $mocked_client->mock('fully_authenticated', sub { return 1 });

        ok $test_client_cr->fully_authenticated, 'Account is fully authenticated';
        ok !$test_client_cr->is_document_expiry_check_required, "Fully authenticated CR account does not have to check documents expiry";
        $mocked_client->unmock_all;
    };

    subtest 'Regulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        $mocked_client->mock('fully_authenticated', sub { return 0 });
        ok $test_client_cr->landing_company->documents_expiration_check_required, 'Regulated company does require expiration check';
        ok $test_client_cr->aml_risk_classification ne 'high', 'Account aml risk is not high';
        ok !$test_client_cr->fully_authenticated, 'Account is not fully authenticated';
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

    ok $client->needs_poi_verification, 'POI is requrired because for false profile info';
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

        my $mocked_client = Test::MockModule->new(ref($test_client));
        $mocked_client->mock('has_deposits', sub { return 1 });
        $uploaded = {};

        $mocked_client->mock('get_poi_status', sub { return 'none' });
        $mocked_client->mock('user',           sub { bless {}, 'BOM::User' });

        my $mocked_user = Test::MockModule->new('BOM::User');
        $mocked_user->mock('has_mt5_regulated_account', sub { return 0 });

        ok !$test_client->status->shared_payment_method, 'Not SPM';
        ok !$test_client->status->age_verification,      'Not age verified';
        ok !$test_client->fully_authenticated, 'Not fully authenticated';
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

        my $mocked_client = Test::MockModule->new(ref($test_client));
        $mocked_client->mock('has_deposits', sub { return 1 });
        $uploaded = {};

        $mocked_client->mock('get_poi_status', sub { return 'none' });
        $mocked_client->mock('user',           sub { bless {}, 'BOM::User' });

        my $mocked_user = Test::MockModule->new('BOM::User');
        $mocked_client->mock('has_mt5_regulated_account', sub { return 0 });

        ok !$test_client->status->shared_payment_method, 'Not SPM';
        ok !$test_client->status->age_verification,      'Not age verified';
        ok !$test_client->fully_authenticated, 'Not fully authenticated';
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
            broker_code => 'MX',
            residence   => 'gb',
            citizen     => 'gb',
            email       => 'nowthatsan@email.com',
            loginid     => 'MLT235711'
        );

        my $mocked_client = Test::MockModule->new(ref($test_client));
        $mocked_client->mock('user', sub { bless {}, 'BOM::User' });
        $uploaded = {};
        ok !$test_client->status->age_verification, 'Not age verified';
        ok !$test_client->fully_authenticated, 'Not fully authenticated';
        ok $test_client->is_verification_required(check_authentication_status => 1), 'Unauthenticated MX account needs verification';
        ok $test_client->needs_poi_verification, 'POI is needed for unauthenticated MX account without deposits';
        ok $test_client->needs_poa_verification, 'POA is needed for unauthenticated MX account without deposits';
        $mocked_client->unmock_all;
    };
};

subtest 'Unsupported Onfido country' => sub {
    my $test_client = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'aq',
        citizen     => 'aq',
        email       => 'nowthatsan@email.com',
        loginid     => 'CR00001618'
    );

    my $mocked_client = Test::MockModule->new(ref($test_client));
    $mocked_client->mock('user',                     sub { bless {}, 'BOM::User' });
    $mocked_client->mock('is_verification_required', sub { return 1 });

    my $mocked_onfido_config = Test::MockModule->new('BOM::Config::Onfido');
    $mocked_onfido_config->mock('is_country_supported', sub { return 0 });

    my $docs   = {};
    my $status = 'verified';

    ok !$test_client->needs_poi_verification($docs, $status), 'POI not needed if the client country is not supported';

    $mocked_onfido_config->mock('is_country_supported', sub { return 1 });

    ok $test_client->needs_poi_verification($docs, $status), 'POI needed if the client country is supported';

    $mocked_client->unmock_all;
    $mocked_onfido_config->unmock_all;
};

subtest 'Experian validated accounts' => sub {
    my $test_client = BOM::User::Client->rnew(
        broker_code => 'MX',
        residence   => 'gb',
        citizen     => 'gb',
        email       => 'nowthatsan@email.com',
        loginid     => 'MLT235711'
    );

    subtest 'POI' => sub {
        my $mocked_client = Test::MockModule->new(ref($test_client));
        my $mocked_status = Test::MockModule->new(ref($test_client->status));
        my $risk;
        my $auth_method;

        $mocked_client->mock(
            'aml_risk_classification',
            sub {
                $risk;
            });
        $mocked_status->mock(
            'age_verification',
            sub {
                {reason => 'Experian results are sufficient to mark client as age verified.'}
            });
        $mocked_status->mock(
            'proveid_requested',
            sub {
                {reason => 'ProveID request has been made for this account.'}
            });
        $mocked_client->mock(
            'get_authentication',
            sub {
                my (undef, $method) = @_;
                return bless({status => 'pass'}, 'BOM::Database::AutoGenerated::Rose::ClientAuthenticationMethod') if $method eq $auth_method;
                return undef;
            });

        subtest 'Low risk' => sub {
            $auth_method = 'ID_ONLINE';
            $risk        = 'low';
            $uploaded    = {};

            ok !$test_client->needs_poi_verification, 'Does not need POI verification';
            is $test_client->get_poi_status, 'verified', 'POI status is verified';
        };

        subtest 'High risk' => sub {
            $auth_method = 'ID_ONLINE';
            $risk        = 'high';
            $uploaded    = {};

            ok $test_client->needs_poi_verification, 'POI verification needed';
            is $test_client->get_poi_status, 'none', 'POI status is none';
        };

        subtest 'High risk but the client has uploaded docs' => sub {
            $auth_method = 'ID_ONLINE';
            $risk        = 'high';
            $uploaded    = {
                proof_of_identity => {
                    is_pending => 1,
                }};

            ok !$test_client->needs_poi_verification, 'POI verification not needed';
            is $test_client->get_poi_status, 'pending', 'POI status is pending';
        };

        subtest 'Under rejected Onfido' => sub {
            $auth_method = 'ID_ONLINE';
            $risk        = 'high';

            my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
            $mocked_onfido->mock(
                'get_latest_check',
                sub {
                    return {
                        report_document_status     => 'complete',
                        report_document_sub_result => 'rejected',
                    };
                });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                }};

            ok $test_client->needs_poi_verification, 'Does need POI verification';
            is $test_client->get_poi_status, 'rejected', 'POI status is rejected';
            $mocked_onfido->unmock_all;
        };

        subtest 'Under rejected Onfido but fully auth with scans' => sub {
            $auth_method = 'ID_DOCUMENT';
            $risk        = 'high';

            my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
            $mocked_onfido->mock(
                'get_latest_check',
                sub {
                    return {
                        report_document_status     => 'complete',
                        report_document_sub_result => 'rejected',
                    };
                });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                }};
            ok !$test_client->needs_poi_verification, 'Does not need POI verification';
            is $test_client->get_poi_status, 'verified', 'POI status is verified';
            $mocked_onfido->unmock_all;
        };

        subtest 'High risk but the verification is from BO' => sub {
            $auth_method = 'ID_ONLINE';
            $risk        = 'high';
            $uploaded    = {
                proof_of_identity => {
                    is_pending => 0,
                }};

            $mocked_status->mock(
                'age_verification',
                sub {
                    {reason => 'Age verified client from Backoffice.'}
                });
            ok !$test_client->needs_poi_verification, 'Does not need POI verification';
            is $test_client->get_poi_status, 'verified', 'POI status is verified';
        };

        $mocked_client->unmock_all;
        $mocked_status->unmock_all;
    };

    subtest 'POA' => sub {
        my $mocked_client = Test::MockModule->new(ref($test_client));
        my $mocked_status = Test::MockModule->new(ref($test_client->status));
        my $auth_method;
        my $risk;

        $mocked_client->mock(
            'aml_risk_classification',
            sub {
                $risk;
            });
        $mocked_status->mock(
            'proveid_requested',
            sub {
                {reason => 'ProveID request has been made for this account.'}
            });

        $mocked_client->mock(
            'get_authentication',
            sub {
                my (undef, $method) = @_;
                return bless({status => 'pass'}, 'BOM::Database::AutoGenerated::Rose::ClientAuthenticationMethod') if $method eq $auth_method;
                return undef;
            });

        subtest 'Low risk' => sub {
            $auth_method = 'ID_ONLINE';
            $risk        = 'low';
            $uploaded    = {};

            ok !$test_client->needs_poa_verification, 'Does not need POA verification';
            is $test_client->get_poa_status, 'verified', 'POA status is verified';
        };

        subtest 'High risk' => sub {
            $auth_method = 'ID_ONLINE';
            $risk        = 'high';
            $uploaded    = {};

            ok $test_client->needs_poa_verification, 'POA verification needed';
            is $test_client->get_poa_status, 'none', 'POA status is none';
        };

        subtest 'High risk but the client has uploaded docs' => sub {
            $auth_method = 'ID_ONLINE';
            $risk        = 'high';
            $uploaded    = {
                proof_of_address => {
                    is_pending => 1,
                }};

            ok !$test_client->needs_poa_verification, 'POA verification not needed';
            is $test_client->get_poa_status, 'pending', 'POA status is pending';
        };

        subtest 'High risk but BO has verified' => sub {
            $auth_method = 'ID_DOCUMENT';
            $risk        = 'high';
            $uploaded    = {
                proof_of_address => {
                    is_pending => 0,
                }};

            ok !$test_client->needs_poa_verification, 'Does not need POA verification';
            is $test_client->get_poa_status, 'verified', 'POA status is verified';
        };

        $mocked_client->unmock_all;
        $mocked_status->unmock_all;
    };
};

subtest 'Ignore age verification' => sub {
    my $test_client = BOM::User::Client->rnew(
        broker_code => 'MX',
        residence   => 'gb',
        citizen     => 'gb',
        email       => 'nowthatsan@email.com',
        loginid     => 'MLT235711'
    );

    my $mocked_client = Test::MockModule->new(ref($test_client));
    my $mocked_status = Test::MockModule->new(ref($test_client->status));
    my $auth_method;
    my $is_experian_validated;
    my $risk;

    $mocked_status->mock(
        'is_experian_validated',
        sub {
            return $is_experian_validated;
        });

    $mocked_client->mock(
        'get_authentication',
        sub {
            my (undef, $method) = @_;
            return bless({status => 'pass'}, 'BOM::Database::AutoGenerated::Rose::ClientAuthenticationMethod') if $method eq $auth_method;
            return undef;
        });

    $mocked_client->mock(
        'aml_risk_classification',
        sub {
            return $risk;
        });

    subtest 'Ignored - base case' => sub {
        $auth_method           = 'ID_ONLINE';
        $is_experian_validated = 1;
        $risk                  = 'high';
        ok $test_client->ignore_age_verification, 'Age verification is ignored';
    };

    subtest 'Not ignored - fully authenticated with scan / notarized' => sub {
        $auth_method           = 'ID_NOTARIZED';
        $is_experian_validated = 1;
        $risk                  = 'high';
        ok !$test_client->ignore_age_verification, 'Age verification is not ignored ID_NOTARIZED';

        $auth_method           = 'ID_DOCUMENT';
        $is_experian_validated = 1;
        $risk                  = 'high';
        ok !$test_client->ignore_age_verification, 'Age verification is not ignored ID_DOCUMENT';
    };

    subtest 'Not ignored - low risk' => sub {
        $auth_method           = 'ID_ONLINE';
        $is_experian_validated = 1;
        $risk                  = 'low';
        ok !$test_client->ignore_age_verification, 'Age verification is not ignored';
    };

    subtest 'Not ignored - not experian validated' => sub {
        $auth_method           = 'ID_ONLINE';
        $is_experian_validated = 0;
        $risk                  = 'low';
        ok !$test_client->ignore_age_verification, 'Age verification is not ignored';
    };

    $mocked_client->unmock_all;
    $mocked_status->unmock_all;
};

subtest 'Ignore address verification' => sub {
    my $test_client = BOM::User::Client->rnew(
        broker_code => 'MX',
        residence   => 'gb',
        citizen     => 'gb',
        email       => 'nowthatsan@email.com',
        loginid     => 'MLT235711'
    );

    my $mocked_client = Test::MockModule->new(ref($test_client));
    my $mocked_status = Test::MockModule->new(ref($test_client->status));
    my $auth_method;
    my $proveid_requested;
    my $risk;

    $mocked_status->mock(
        'proveid_requested',
        sub {
            return $proveid_requested;
        });

    $mocked_client->mock(
        'get_authentication',
        sub {
            my (undef, $method) = @_;
            return bless({status => 'pass'}, 'BOM::Database::AutoGenerated::Rose::ClientAuthenticationMethod') if $method eq $auth_method;
            return undef;
        });

    $mocked_client->mock(
        'aml_risk_classification',
        sub {
            return $risk;
        });

    subtest 'Ignored - base case' => sub {
        $auth_method       = 'ID_ONLINE';
        $proveid_requested = 1;
        $risk              = 'high';
        ok $test_client->ignore_address_verification, 'Address verification is ignored';
    };

    subtest 'Not ignored - fully authenticated with scan / notarized' => sub {
        $auth_method       = 'ID_NOTARIZED';
        $proveid_requested = 1;
        $risk              = 'high';
        ok !$test_client->ignore_address_verification, 'Address verification is not ignored ID_NOTARIZED';

        $auth_method       = 'ID_DOCUMENT';
        $proveid_requested = 1;
        $risk              = 'high';
        ok !$test_client->ignore_address_verification, 'Address verification is not ignored ID_DOCUMENT';
    };

    subtest 'Not ignored - low risk' => sub {
        $auth_method       = 'ID_ONLINE';
        $proveid_requested = 1;
        $risk              = 'low';
        ok !$test_client->ignore_address_verification, 'Address verification is not ignored';
    };

    subtest 'Not ignored - not proveid_requested' => sub {
        $auth_method       = 'ID_ONLINE';
        $proveid_requested = 0;
        $risk              = 'low';
        ok !$test_client->ignore_address_verification, 'Address verification is not ignored';
    };

    $mocked_client->unmock_all;
    $mocked_status->unmock_all;
};

subtest 'Onfido status' => sub {
    my $test_client = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'br',
        citizen     => 'br',
        email       => 'onfido-status@email.com',
        loginid     => 'CR1317189'
    );

    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    my $mocked_config = Test::MockModule->new('BOM::Config::Onfido');
    my $mocked_client = Test::MockModule->new('BOM::User::Client');

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
    $mocked_client->mock(
        'documents_uploaded',
        sub {
            return {proof_of_identity => $docs};
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
            is_supported_country   => 1,
            onfido_document_status => 'complete',
            onfido_check_result    => 'clear',
            docs                   => {
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
            status => 'verified'
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
        }];

    for my $test ($tests->@*) {
        my $status;

        ($is_supported_country, $onfido_document_status, $onfido_check_result, $onfido_sub_result, $docs, $status) =
            @{$test}{qw/is_supported_country onfido_document_status onfido_check_result onfido_sub_result docs status/};

        is $test_client->get_onfido_status, $status, "Got the expected status=$status";
    }

    $mocked_onfido->unmock_all;
    $mocked_config->unmock_all;
    $mocked_client->unmock_all;
};

subtest 'Manual POI status' => sub {
    my $test_client = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'br',
        citizen     => 'br',
        email       => 'manual-poi-status@email.com',
        loginid     => 'CR1317184'
    );

    my $mocked_config = Test::MockModule->new('BOM::Config::Onfido');
    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    my $mocked_status = Test::MockModule->new('BOM::User::Client::Status');

    my $age_verification;
    $mocked_status->mock(
        'age_verification',
        sub {
            return $age_verification;
        });

    my $is_supported_country;
    $mocked_config->mock(
        'is_country_supported',
        sub {
            return $is_supported_country;
        });

    my ($is_expired, $is_pending);
    $mocked_client->mock(
        'documents_uploaded',
        sub {
            return {
                proof_of_identity => {
                    is_expired => $is_expired,
                    is_pending => $is_pending,
                },
            };
        });

    my $tests = [{
            is_country_supported => 1,
            status               => 'none',
        },
        {
            is_pending => 1,
            status     => 'pending',
        },
        {
            is_expired => 1,
            status     => 'expired',
        },
        {
            age_verification => 1,
            status           => 'verified',
        },
        {
            # it keeps happening
            is_country_supported => 0,
            status               => 'none',
        }];

    for my $test ($tests->@*) {
        my $status;

        ($is_expired, $is_pending, $is_supported_country, $age_verification, $status) =
            @{$test}{qw/is_expired is_pending is_supported_country age_verification status/};

        is $test_client->get_manual_poi_status, $status, "Got the expected status=$status";
    }

    $mocked_status->unmock_all;
    $mocked_config->unmock_all;
    $mocked_client->unmock_all;
};

subtest 'POI attempts' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
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
                    timestamp    => $now->epoch,
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
                    timestamp    => $now->epoch,
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
                    timestamp    => $now->epoch,
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
                }
            ],
            results => [{
                    service      => 'idv',
                    status       => 'pending',
                    country_code => 'ng',
                    id           => '1',
                    timestamp    => $now->epoch,
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
                }
            ],
            results => [{
                    service      => 'idv',
                    status       => 'rejected',
                    country_code => 'za',
                    id           => '2',
                    timestamp    => $now->epoch,
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
                }
            ],
            results => [{
                    service      => 'idv',
                    status       => 'rejected',
                    country_code => 'gh',
                    id           => '3',
                    timestamp    => $now->epoch,
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
                }
            ],
            results => [{
                    service      => 'idv',
                    status       => 'verified',
                    country_code => 'ke',
                    id           => '4',
                    timestamp    => $now->epoch,
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
                }
            ],
            results => [{
                    service      => 'onfido',
                    status       => 'pending',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 'onfido-test-1',
                    timestamp    => $after->epoch,
                },
                {
                    service      => 'idv',
                    status       => 'verified',
                    country_code => 'ke',
                    id           => '4',
                    timestamp    => $before->epoch,
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
                }
            ],
            results => [{
                    service      => 'idv',
                    status       => 'verified',
                    country_code => 'ke',
                    id           => '4',
                    timestamp    => $after->epoch,
                },
                {
                    service      => 'onfido',
                    status       => 'pending',
                    country_code => $client->place_of_birth // $client->residence,
                    id           => 'onfido-test-1',
                    timestamp    => $before->epoch,
                }
            ],
        },
    ];

    for my $test ($tests->@*) {
        my ($title, $onfido, $idv, $results) = @{$test}{qw/title onfido idv results/};

        $onfido_list = $onfido;
        $idv_list    = $idv;

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
};

done_testing();
