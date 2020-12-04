use strict;
use warnings;
use Test::More;
use Test::MockModule;
use BOM::User::Client;
use BOM::User;

use BOM::Test::Data::Utility::UnitTestDatabase;

subtest 'get_poa_status' => sub {
    subtest 'Unregulated account' => sub {
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        my $mocked_client = Test::MockModule->new(ref($test_client_cr));
        subtest 'POA status none' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_expired  => 0,
                            is_pending  => 0,
                            is_rejected => 0,
                        }};
                });

            is $test_client_cr->get_poa_status, 'none', 'Client POA status is none';
            $mocked_client->unmock_all;
        };

        subtest 'POA status expired' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_expired  => 1,
                            is_pending  => 0,
                            is_rejected => 0,
                        }};
                });

            is $test_client_cr->get_poa_status, 'expired', 'Client POA status is expired';
            $mocked_client->unmock_all;
        };

        subtest 'POA status pending' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_expired  => 0,
                            is_pending  => 1,
                            is_rejected => 0,
                        }};
                });

            is $test_client_cr->get_poa_status, 'pending', 'Client POA status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POA status rejected' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_expired  => 0,
                            is_pending  => 0,
                            is_rejected => 1,
                        }};
                });

            is $test_client_cr->get_poa_status, 'rejected', 'Client POA status is rejected';
            $mocked_client->unmock_all;
        };

        subtest 'POA status verified' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 1 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_expired  => 0,
                            is_pending  => 0,
                            is_rejected => 0,
                        }};
                });

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
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_expired  => 0,
                            is_pending  => 0,
                            is_rejected => 0,
                        }};
                });

            is $test_client_mf->get_poa_status, 'none', 'Client POA status is none';
            $mocked_client->unmock_all;
        };

        subtest 'POA status expired' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_expired  => 1,
                            is_pending  => 0,
                            is_rejected => 0,
                        }};
                });

            is $test_client_mf->get_poa_status, 'expired', 'Client POA status is expired';
            $mocked_client->unmock_all;
        };

        subtest 'POA status pending' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_expired  => 0,
                            is_pending  => 1,
                            is_rejected => 0,
                        }};
                });

            is $test_client_mf->get_poa_status, 'pending', 'Client POA status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POA status rejected' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_expired  => 0,
                            is_pending  => 0,
                            is_rejected => 1,
                        }};
                });

            is $test_client_mf->get_poa_status, 'rejected', 'Client POA status is rejected';
            $mocked_client->unmock_all;
        };

        subtest 'POA status verified' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 1 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_expired  => 0,
                            is_pending  => 0,
                            is_rejected => 0,
                        }};
                });

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
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 0,
                        }};
                });

            is $test_client_cr->get_poi_status, 'none', 'Client POI status is none';
            $mocked_client->unmock_all;
        };

        subtest 'POI status expired' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 1,
                        }};
                });

            is $test_client_cr->get_poi_status, 'expired', 'Client POI status is expired';
            $mocked_client->unmock_all;
        };

        subtest 'POI status pending' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 0,
                        }};
                });

            $onfido_document_status = 'in_progress';
            is $test_client_cr->get_poi_status, 'pending', 'Client POI status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POI status is pending' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_pending => 1,
                        }};
                });

            $onfido_document_status = undef;
            is $test_client_cr->get_poi_status, 'pending', 'Client POI status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POI documents expired but onfido status in_progress' => sub {
            $onfido_document_status = 'in_progress';
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 1,
                        }};
                });

            is $test_client_cr->get_poi_status, 'pending', 'Client POI status is expired';
            $mocked_client->unmock_all;
        };

        subtest 'POI status rejected' => sub {
            $onfido_document_status = 'complete';
            $onfido_sub_result      = 'rejected';
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 0,
                        }};
                });

            is $test_client_cr->get_poi_status, 'rejected', 'Client POI status is rejected';
            $mocked_client->unmock_all;
            $onfido_document_status = undef;
            $onfido_sub_result      = undef;
        };

        subtest 'POI status suspected' => sub {
            $onfido_document_status = 'complete';
            $onfido_sub_result      = 'suspected';
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 0,
                        }};
                });

            is $test_client_cr->get_poi_status, 'suspected', 'Client POI status is suspected';
            $mocked_client->unmock_all;
            $onfido_document_status = undef;
            $onfido_sub_result      = undef;
        };

        subtest 'POI status verified' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 1 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 0,
                        }};
                });

            is $test_client_cr->get_poi_status, 'verified', 'Client POI status is verified';
            $mocked_client->unmock_all;
        };

        subtest 'POI status rejected - fully authenticated or age verified' => sub {
            $test_client_cr->status->clear_age_verification;
            my $authenticated = 1;
            $mocked_client->mock('fully_authenticated', sub { return $authenticated });
            my $expiry_check_required = 1;
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return $expiry_check_required });
            my $poi_expired = 0;
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => $poi_expired,
                        }};
                });
            my $authenticated_test_scenarios = sub {
                $poi_expired            = 0;
                $expiry_check_required  = 1;
                $onfido_document_status = 'complete';
                $onfido_sub_result      = 'rejected';
                is $test_client_cr->get_poi_status, 'verified',
                    'POI status of an authenticated client is <verified> - even with rejected onfido check';

                $poi_expired = 1;
                is $test_client_cr->get_poi_status, 'expired', 'POI status of an authenticated client is <expired> - if expiry check is required';

                $expiry_check_required = 0;
                is $test_client_cr->get_poi_status, 'verified',
                    'POI status of an authenticated client is <verified> - if expiry check is not required';
            };

            $authenticated = 1;
            $authenticated_test_scenarios->();

            $authenticated = 0;
            $test_client_cr->status->set('age_verification', 'system', 'test');
            $authenticated_test_scenarios->();

            $test_client_cr->status->clear_age_verification;

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
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 0,
                        }};
                });

            is $test_client_mf->get_poi_status, 'none', 'Client POI status is none';
            $mocked_client->unmock_all;
        };

        subtest 'POI status expired' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 1,
                        }};
                });

            is $test_client_mf->get_poi_status, 'expired', 'Client POI status is expired';
            $mocked_client->unmock_all;
        };

        subtest 'POI status pending' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 0,
                        }};
                });

            $onfido_document_status = 'awaiting_applicant';
            is $test_client_mf->get_poi_status, 'pending', 'Client POI status is pending';
            $mocked_client->unmock_all;
        };

        subtest 'POI status rejected' => sub {
            $onfido_document_status = 'complete';
            $onfido_sub_result      = 'rejected';
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 0,
                        }};
                });

            is $test_client_mf->get_poi_status, 'rejected', 'Client POI status is rejected';
            $mocked_client->unmock_all;
            $onfido_document_status = undef;
            $onfido_sub_result      = undef;
        };

        subtest 'POI status suspected' => sub {
            $onfido_document_status = 'complete';
            $onfido_sub_result      = 'suspected';
            $mocked_client->mock('fully_authenticated',                   sub { return 0 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 0,
                        }};
                });

            is $test_client_mf->get_poi_status, 'suspected', 'Client POI status is suspected';
            $mocked_client->unmock_all;
            $onfido_document_status = undef;
            $onfido_sub_result      = undef;
        };

        subtest 'POI status verified' => sub {
            $mocked_client->mock('fully_authenticated',                   sub { return 1 });
            $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            is_expired => 0,
                        }};
                });

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
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            documents => 'something',
                        }};
                });
            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });

            ok !$test_client_cr->needs_poa_verification, 'POA is not needed';
            $mocked_client->unmock_all;
        };

        subtest 'Verification is needed' => sub {
            $mocked_client->mock('get_poa_status', sub { return 'expired' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_address => {documents => undef}};
                });

            ok $test_client_cr->needs_poa_verification, 'POA is needed due to expired POA status';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status', sub { return 'rejected' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_address => {documents => undef}};
                });

            ok $test_client_cr->needs_poa_verification, 'POA is needed due to rejected POA status';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status',           sub { return 'none' });
            $mocked_client->mock('fully_authenticated',      sub { return 0 });
            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_address => {documents => undef}};
                });

            ok $test_client_cr->needs_poa_verification, 'POA is needed due not fully authenticated and authentication needed';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status',           sub { return 'verified' });
            $mocked_client->mock('fully_authenticated',      sub { return 1 });
            $mocked_client->mock('is_verification_required', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            documents => 'something',
                        }};
                });
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
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            documents => 'something',
                        }};
                });
            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });

            ok !$test_client_mf->needs_poa_verification, 'POA is not needed';
            $mocked_client->unmock_all;
        };

        subtest 'Verification is needed' => sub {
            $mocked_client->mock('get_poa_status', sub { return 'expired' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_address => {documents => undef}};
                });

            ok $test_client_mf->needs_poa_verification, 'POA is needed due to expired POA status';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status', sub { return 'rejected' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_address => {documents => undef}};
                });

            ok $test_client_mf->needs_poa_verification, 'POA is needed due to rejected POA status';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status',      sub { return 'none' });
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_address => {documents => undef}};
                });

            ok $test_client_mf->needs_poa_verification, 'POA is needed due not fully authenticated and authentication needed';
            $mocked_client->unmock_all;

            $mocked_client->mock('get_poa_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            documents => 'something',
                        }};
                });
            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
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
        subtest 'Not needed' => sub {
            $mocked_client->mock('get_poi_status',      sub { return 'verified' });
            $mocked_client->mock('fully_authenticated', sub { return 1 });
            $mocked_status->mock('age_verification',    sub { return 1 });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            documents => 'something',
                        }};
                });
            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });

            ok !$test_client_cr->needs_poi_verification, 'POI is not needed';

            $mocked_client->mock('get_poi_status', sub { return 'rejected' });
            ok !$test_client_cr->needs_poi_verification,
                'POI is not needed for fully authenticated and age verified - even if poi status is <rejected>';

            $mocked_client->unmock_all;
            $mocked_status->unmock_all;
        };

        subtest 'Verification is needed' => sub {
            $mocked_client->mock('get_poi_status', sub { return 'expired' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            ok $test_client_cr->needs_poi_verification, 'POI is needed due to expired POI status';
            $mocked_client->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            ok $test_client_cr->needs_poi_verification, 'POI is needed due to verification required and current status is none';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 0 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            $onfido_sub_result = 'rejected';
            ok $test_client_cr->needs_poi_verification, 'POI is needed due to onfido rejected sub result';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 0 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            $onfido_sub_result = 'suspected';
            ok $test_client_cr->needs_poi_verification, 'POI is needed due to onfido suspected sub result';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 0 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            $onfido_sub_result = 'caution';
            ok $test_client_cr->needs_poi_verification, 'POI is needed due to onfido caution sub result';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            $onfido_sub_result = undef;
            $onfido_applicant  = undef;
            ok $test_client_cr->needs_poi_verification, 'POI is needed due to verification required and no POI documents seen';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            documents => 'something',
                        }};
                });

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
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            documents => 'something',
                        }};
                });
            $mocked_client->mock(
                'binary_user_id' => sub {
                    return 'mocked';
                });

            ok !$test_client_mf->needs_poi_verification, 'POI is not needed';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;
        };

        subtest 'Verification is needed' => sub {
            $mocked_client->mock('get_poi_status', sub { return 'expired' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            ok $test_client_mf->needs_poi_verification, 'POI is needed due to expired POI status';
            $mocked_client->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'none' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            ok $test_client_mf->needs_poi_verification, 'POI is needed due to verification required and current status is none';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            $onfido_sub_result = 'rejected';
            ok $test_client_mf->needs_poi_verification, 'POI is needed due to onfido rejected sub result';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            $onfido_sub_result = 'suspected';
            ok $test_client_mf->needs_poi_verification, 'POI is needed due to onfido suspected sub result';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            $onfido_sub_result = 'caution';
            ok $test_client_mf->needs_poi_verification, 'POI is needed due to onfido caution sub result';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {proof_of_identity => {documents => undef}};
                });

            $onfido_sub_result = undef;
            $onfido_applicant  = undef;
            ok $test_client_mf->needs_poi_verification, 'POI is needed due to verification required and no POI documents seen';
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            $mocked_client->mock('is_verification_required', sub { return 1 });
            $mocked_client->mock('get_poi_status',           sub { return 'pending' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            documents => 'something',
                        }};
                });

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
    $mocked_client->mock('is_verification_required',              sub { return 0 });
    $mocked_client->mock('fully_authenticated',                   sub { return 0 });
    $mocked_client->mock('age_verification',                      sub { return 0 });
    $mocked_client->mock('is_document_expiry_check_required_mt5', sub { return 0 });
    $mocked_client->mock(
        'documents_uploaded',
        sub {
            return {};
        });

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
            return 'mocked';
        });

    ok !$test_client_cr->needs_poi_verification, 'Shared PM is gone and so does the needs POI verification';

    $mocked_client->unmock_all;
    $mocked_status->unmock_all;
    $mocked_onfido->unmock_all;
};

done_testing();
