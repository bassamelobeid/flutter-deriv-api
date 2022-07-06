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
                    documents  => {},
                }};

            is $test_client_cr->get_poi_status, 'none', 'Client POI status is none';
            $mocked_client->unmock_all;
        };

        subtest 'POI status expired for uploaded files' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    documents  => {},
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
                    documents  => {},
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
                        documents  => {},
                    }};
                $onfido_document_status = 'in_progress';
                is $test_client_cr->get_poi_status, 'pending', 'Client POI status is still pending';
                $mocked_client->unmock_all;
            };
        };

        subtest 'POI status is pending' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $mocked_client->mock('latest_poi_by',       sub { return undef });

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
            $mocked_client->mock('latest_poi_by',       sub { return 'onfido' });

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
            $mocked_client->mock('latest_poi_by',       sub { return 'onfido' });

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
            $mocked_client->mock('latest_poi_by',       sub { return 'onfido' });

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
            $mocked_client->mock('fully_authenticated',               sub { return $authenticated });
            $mocked_client->mock('latest_poi_by',                     sub { return 'onfido' });
            $mocked_client->mock('is_document_expiry_check_required', sub { return 1 });

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

        subtest 'First Onfido upload and no check was made just yet' => sub {
            $mocked_client->mock('fully_authenticated', sub { return 0 });
            $mocked_client->mock('latest_poi_by',       sub { return undef });

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    documents  => {},
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
            my $idv = 'none';
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

            $uploaded = {
                proof_of_identity => {
                    is_pending => 1,
                    documents  => {
                        asdf => {},
                    },
                },
            };

            is $test_client_cr->get_poi_status,        'pending',  'poi status = pending';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'pending',  'manual status = pending';

            $uploaded = {
                proof_of_identity => {
                    is_pending => 0,
                    documents  => {
                        asdf => {},
                    },
                },
            };

            is $test_client_cr->get_poi_status,        'rejected', 'poi status = rejected';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'rejected', 'manual status = rejected';

            $uploaded = {
                proof_of_identity => {
                    is_pending => 0,
                    documents  => {
                        asdf => {},
                    },
                },
            };

            $test_client_cr->status->setnx('age_verification', 'test', 'test');
            is $test_client_cr->get_poi_status,        'verified', 'poi status = verified';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'verified', 'manual status = verified';

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    documents  => {
                        asdf => {},
                    },
                },
            };

            is $test_client_cr->get_poi_status,        'expired',  'poi status = expired';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'expired',  'manual status = expired';

            $uploaded = {
                proof_of_identity => {
                    is_expired => 1,
                    is_pending => 1,
                    documents  => {
                        asdf => {},
                        test => {},
                    },
                },
            };

            is $test_client_cr->get_poi_status,        'pending',  'poi status = pending';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'pending',  'manual status = pending';

            $uploaded = {
                proof_of_identity => {
                    is_expired => 0,
                    is_pending => 0,
                    documents  => {
                        asdf => {},
                        test => {},
                    },
                },
            };

            is $test_client_cr->get_poi_status,        'verified', 'poi status = verified';
            is $test_client_cr->get_idv_status,        'rejected', 'idv status = rejected';
            is $test_client_cr->get_manual_poi_status, 'verified', 'manual status = verified';
        }
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
    };

    $mocked_onfido->unmock_all;
};

done_testing();
