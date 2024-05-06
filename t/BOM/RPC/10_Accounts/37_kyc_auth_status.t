use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::QueueClient;
use List::Util;
use Encode;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::Platform::Utility;
use BOM::User;
use BOM::User::Password;
use BOM::User::Onfido;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Token;

use BOM::Config::Redis;

BOM::Test::Helper::Token::cleanup_redis_tokens();
BOM::Test::Helper::P2P::bypass_sendbird();

my $c = Test::BOM::RPC::QueueClient->new();
my $m = BOM::Platform::Token::API->new;

my $method = 'kyc_auth_status';
subtest 'kyc authorization status' => sub {

    subtest 'test 0' => sub {
        my $user_cr = BOM::User->create(
            email    => 'kyc_test0@deriv.com',
            password => 'secret_pwd'
        );

        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'CR',
            binary_user_id => $user_cr->id,
        });

        $user_cr->add_client($client_cr);

        my $token_cr = $m->create_token($client_cr->loginid, 'test token');

        my $result = $c->tcall($method, {token => $token_cr});
        is $result->{error}, undef, 'Call has no errors';
    };

    subtest 'token validations' => sub {
        my $user_cr = BOM::User->create(
            email    => 'kyc_token@deriv.com',
            password => 'secret_pwd'
        );

        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $user_cr->add_client($client_cr);

        my $client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $client_disabled->status->set('disabled', 1, 'test disabled');

        my $token_disabled = $m->create_token($client_disabled->loginid, 'test token');
        my $token_cr       = $m->create_token($client_cr->loginid,       'test token');

        is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'error if invalid token');

        is(
            $c->tcall(
                $method,
                {
                    token => undef,
                }
            )->{error}{message_to_client},
            'The token is invalid.',
            'error if no token'
        );

        is(
            $c->tcall(
                $method,
                {
                    token => $token_disabled,
                }
            )->{error}{message_to_client},
            'This account is unavailable.',
            'error if disabled account'
        );

        isnt(
            $c->tcall(
                $method,
                {
                    token => $token_cr,
                }
            )->{error}{message_to_client},
            'The token is invalid.',
            'no error if token is valid'
        );
    };

    subtest 'virtual client' => sub {
        my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });

        my $user_vr = BOM::User->create(
            email    => 'kyc_virtual@deriv.com',
            password => 'secret_pwd'
        );

        $user_vr->add_client($client_vr);

        my $token_vr = $m->create_token($client_vr->loginid, 'test token');
        my $result   = $c->tcall($method, {token => $token_vr});

        my $default_response_object = {
            identity => {
                last_rejected      => {},
                available_services => [],
                service            => 'none',
                status             => 'none',
            },
            address => {
                status => 'none',
            },
        };

        cmp_deeply($result, $default_response_object, 'default response object for virtual client');
    };

    subtest 'POA object' => sub {
        subtest 'POA state machine' => sub {
            my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $user_cr = BOM::User->create(
                email    => 'kyc_poa_state_machine@deriv.com',
                password => 'secret_pwd'
            );

            $user_cr->add_client($client_cr);

            my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
            # mocks uploaded

            my $documents_uploaded;
            $documents_mock->mock(
                'uploaded',
                sub {
                    my ($self) = @_;
                    $self->_clear_uploaded;
                    return $documents_uploaded // {};
                });

            my $token_cr = $m->create_token($client_cr->loginid, 'test token');
            my $result   = $c->tcall($method, {token => $token_cr});

            is $result->{address}->{status}, 'none', 'null -> none';

            $documents_uploaded = {
                proof_of_address => {
                    documents => {
                        test => {
                            test => 1,
                        }
                    },
                    is_pending => 1,
                },
            };

            $result = $c->tcall($method, {token => $token_cr});

            is $result->{address}->{status}, 'pending', 'none -> pending';

            $documents_uploaded = {
                proof_of_address => {
                    documents => {
                        test => {
                            test => 1,
                        }
                    },
                    is_rejected => 1,
                },
            };

            $result = $c->tcall($method, {token => $token_cr});
            is $result->{address}->{status}, 'rejected', 'pending -> rejected';

            $documents_uploaded = {
                proof_of_address => {
                    documents => {
                        test => {
                            test => 1,
                        }
                    },
                    is_pending => 1,
                },
            };
            $client_cr->set_authentication('ID_DOCUMENT', {status => 'under_review'});

            $result = $c->tcall($method, {token => $token_cr});
            is $result->{address}->{status}, 'pending', 'rejected -> pending';

            $documents_uploaded = {
                proof_of_address => {
                    documents => {
                        test => {
                            test => 1,
                        }
                    },
                    is_outdated => 1,
                },
            };

            $result = $c->tcall($method, {token => $token_cr});
            is $result->{address}->{status}, 'expired', 'pending -> expired';

            $client_cr->set_authentication('ID_DOCUMENT', {status => 'pass'});

            $result = $c->tcall($method, {token => $token_cr});
            ok $client_cr->fully_authenticated, 'client is fully authenticated';
            is $result->{address}->{status}, 'expired', 'expired -> expired even for fully auth';

            $documents_uploaded = {
                proof_of_address => {
                    documents => {
                        test => {
                            test => 1,
                        }
                    },
                    is_pending => 1,
                },
            };

            $client_cr->set_authentication('ID_DOCUMENT', {status => 'under_review'});

            $result = $c->tcall($method, {token => $token_cr});
            is $result->{address}->{status}, 'pending', 'expired -> pending';

            $documents_uploaded = {
                proof_of_address => {
                    documents => {
                        test => {
                            test => 1,
                        }
                    },
                    is_verified => 1,
                },
            };

            $client_cr->set_authentication('ID_DOCUMENT', {status => 'pass'});

            $result = $c->tcall($method, {token => $token_cr});
            is $result->{address}->{status}, 'verified', 'pending -> verified';

            $documents_uploaded = {
                proof_of_address => {
                    documents => {
                        test => {
                            test => 1,
                        }
                    },
                    is_outdated => 1,
                },
            };

            $result = $c->tcall($method, {token => $token_cr});
            is $result->{address}->{status}, 'expired', 'verified -> expired';

            $documents_mock->unmock_all;
        };

        subtest 'fully authenticated client' => sub {
            my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $user_cr = BOM::User->create(
                email    => 'kyc_fully_auth@deriv.com',
                password => 'secret_pwd'
            );

            $user_cr->add_client($client_cr);

            $client_cr->set_authentication('ID_DOCUMENT', {status => 'pass'});
            $client_cr->save;

            my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
            $status_mock->mock(
                age_verification => +{
                    staff_name         => 'mr cat',
                    reason             => 'test',
                    last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
                });

            my $expected_response = {
                identity => {
                    last_rejected      => {},
                    available_services => ['manual'],
                    service            => 'manual',
                    status             => 'verified',
                },
                address => {
                    status => 'verified',
                },
            };

            my $token_cr = $m->create_token($client_cr->loginid, 'test token');
            my $result   = $c->tcall($method, {token => $token_cr});

            ok $client_cr->fully_authenticated,      'client is fully authenticated';
            ok $client_cr->status->age_verification, 'client is age verified';

            cmp_deeply($result, $expected_response, 'expected poa object for authenticated client');
            $status_mock->unmock_all;
        };
    };

    subtest 'POI object' => sub {
        subtest 'POI available_services' => sub {
            my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $user_cr = BOM::User->create(
                email    => 'kyc_poi_available@deriv.com',
                password => 'secret_pwd'
            );

            $user_cr->add_client($client_cr);

            my $token_cr = $m->create_token($client_cr->loginid, 'test token');

            my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');
            # mocks is_available

            my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
            #mocks is_available

            my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
            # mocks is_upload_available

            my $test_cases = [{
                    idv_is_available            => 1,
                    onfido_is_available         => 1,
                    manual_is_available         => 1,
                    expected_available_services => ['idv', 'onfido', 'manual'],
                },
                {
                    idv_is_available            => 0,
                    onfido_is_available         => 1,
                    manual_is_available         => 1,
                    expected_available_services => ['onfido', 'manual'],
                },
                {
                    idv_is_available            => 1,
                    onfido_is_available         => 0,
                    manual_is_available         => 1,
                    expected_available_services => ['idv', 'manual'],
                },
                {
                    idv_is_available            => 1,
                    onfido_is_available         => 1,
                    manual_is_available         => 0,
                    expected_available_services => ['idv', 'onfido'],
                },
                {
                    idv_is_available            => 1,
                    onfido_is_available         => 0,
                    manual_is_available         => 0,
                    expected_available_services => ['idv'],
                },
                {
                    idv_is_available            => 0,
                    onfido_is_available         => 1,
                    manual_is_available         => 0,
                    expected_available_services => ['onfido'],
                },
                {
                    idv_is_available            => 0,
                    onfido_is_available         => 0,
                    manual_is_available         => 1,
                    expected_available_services => ['manual'],
                },
            ];

            for my $test_case ($test_cases->@*) {
                $idv_mock->mock(is_available => $test_case->{idv_is_available});

                $onfido_mock->mock(is_available => $test_case->{onfido_is_available});

                $documents_mock->mock(is_upload_available => $test_case->{manual_is_available});

                my $result = $c->tcall($method, {token => $token_cr});

                cmp_deeply($result->{identity}->{available_services}, $test_case->{expected_available_services}, 'expected available services');
            }

            $idv_mock->unmock_all;
            $onfido_mock->unmock_all;
            $documents_mock->unmock_all;

            subtest 'duplicated accounts: idv disallowed' => sub {
                my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'CR',
                });

                my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'VRTC',
                });

                my $user = BOM::User->create(
                    email    => 'kyc_dup_idv_disallowed@deriv.com',
                    password => 'secret_pwd'
                );

                $user->add_client($client_cr);
                $user->add_client($client_vr);

                my $token_cr = $m->create_token($client_cr->loginid, 'test token');
                my $result   = $c->tcall($method, {token => $token_cr});

                cmp_deeply $result->{identity}->{available_services}, ['idv', 'onfido', 'manual'], 'idv is not disallowed';

                # make the account duplicated
                $client_cr->status->set('duplicate_account', 'system', 'Duplicate account - currency change');

                my $token_vr = $m->create_token($client_vr->loginid, 'virtual token');

                $result = $c->tcall($method, {token => $token_vr});
                cmp_deeply $result->{identity}->{available_services}, ['idv', 'onfido', 'manual'], 'idv is not disallowed';

                $client_cr->aml_risk_classification('high');
                $client_cr->save;

                $result = $c->tcall($method, {token => $token_vr});
                cmp_deeply $result->{identity}->{available_services}, ['onfido', 'manual'], 'high risk makes the client idv_disallowed';
            };

            subtest 'duplicated accounts: zero idv submissions left' => sub {
                my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'CR',
                });

                my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'VRTC',
                });

                my $user = BOM::User->create(
                    email    => 'kyc_dup_idv_zero@deriv.com',
                    password => 'secret_pwd'
                );

                $user->add_client($client_cr);
                $user->add_client($client_vr);

                my $token_cr = $m->create_token($client_cr->loginid, 'test token');
                my $result   = $c->tcall($method, {token => $token_cr});
                cmp_deeply $result->{identity}->{available_services}, ['idv', 'onfido', 'manual'], 'idv is available';

                # make the account duplicated
                $client_cr->status->set('duplicate_account', 'system', 'Duplicate account - currency change');

                my $idv_mock         = Test::MockModule->new('BOM::User::IdentityVerification');
                my $submissions_left = 0;
                $idv_mock->mock(
                    'submissions_left',
                    sub {
                        return $submissions_left;
                    });

                my $token_vr = $m->create_token($client_vr->loginid, 'virtual token');

                $result = $c->tcall($method, {token => $token_vr});
                cmp_deeply $result->{identity}->{available_services}, ['onfido', 'manual'], 'idv is not available (skip idv)';

                $submissions_left = 1;

                $result = $c->tcall($method, {token => $token_vr});
                cmp_deeply $result->{identity}->{available_services}, ['idv', 'onfido', 'manual'], 'idv is available';

                $idv_mock->unmock_all;
            };
        };

        subtest 'POI last_rejected, service, status' => sub {
            subtest 'latest_poi_by: none' => sub {
                my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'CR',
                });

                my $user_cr = BOM::User->create(
                    email    => 'kyc_latest_poi_by_none@deriv.com',
                    password => 'secret_pwd'
                );

                $user_cr->add_client($client_cr);

                my $token_cr = $m->create_token($client_cr->loginid, 'test token');

                my $latest_poi_by = 'none';
                my $test_case     = {
                    title             => "Testing latest poi by: 'none'",
                    latest_poi_by     => $latest_poi_by,
                    manual_poi_status => 'none',
                    expected_result   => {
                        last_rejected => {},
                        poi_status    => 'none',
                    },
                };

                my $result = $c->tcall($method, {token => $token_cr});

                my $title = $test_case->{title};

                cmp_deeply($result->{identity}->{service}, $test_case->{latest_poi_by}, "expected poi_service for test: $title");

                cmp_deeply($result->{identity}->{status}, $test_case->{expected_result}->{poi_status}, "expected poi_status for test: $title");

                cmp_deeply(
                    $result->{identity}->{last_rejected},
                    $test_case->{expected_result}->{last_rejected},
                    "expected last_rejected for test: $title"
                );
            };

            subtest 'latest_poi_by: idv' => sub {
                my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'CR',
                });

                my $user_cr = BOM::User->create(
                    email    => 'kyc_latest_poi_by_idv@deriv.com',
                    password => 'secret_pwd'
                );

                $user_cr->add_client($client_cr);

                my $client_mock = Test::MockModule->new('BOM::User::Client');
                # mocks latest_poi_by

                my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
                # mocks age_verification

                my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');
                # mocks get_last_updated_document

                my $idv_rejected_reasons = BOM::Platform::Utility::rejected_identity_verification_reasons_error_codes();

                my $non_expired_date = Date::Utility->today->_plus_years(1);
                my $expired_date     = Date::Utility->today->_minus_years(1);

                my $token_cr = $m->create_token($client_cr->loginid, 'test token');

                my $test_cases = [];

                my $latest_poi_by = 'idv';
                push $test_cases->@*, (
                    map {
                        +{
                            title                     => "Testing latest poi by: $latest_poi_by, $_",
                            latest_poi_by             => $latest_poi_by,
                            idv_last_updated_document => {
                                status          => 'refuted',
                                status_messages => "[\"$_\"]",
                                document_type   => 'passport',
                            },
                            expected_result => {
                                last_rejected => {
                                    rejected_reasons => [$idv_rejected_reasons->{$_}],
                                    document_type    => 'passport',
                                    report_available => 1
                                },
                                poi_status => 'rejected',
                            },
                        }
                    } keys $idv_rejected_reasons->%*
                );

                push $test_cases->@*,
                    ({
                        title                     => "Testing latest poi by: $latest_poi_by, multiple messages",
                        latest_poi_by             => $latest_poi_by,
                        idv_last_updated_document => {
                            status          => 'refuted',
                            status_messages => "[\"UNDERAGE\", \"NAME_MISMATCH\"]",
                            document_type   => 'passport',
                        },
                        expected_result => {
                            last_rejected => {
                                rejected_reasons => [map { $idv_rejected_reasons->{$_} } qw/UNDERAGE NAME_MISMATCH/],
                                document_type    => 'passport',
                                report_available => 1
                            },
                            poi_status => 'rejected',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, fake messages",
                        latest_poi_by             => $latest_poi_by,
                        idv_last_updated_document => {
                            status          => 'refuted',
                            status_messages => "[\"UNDERAGE\", \"garbage!!\"]",
                            document_type   => 'passport',
                        },
                        expected_result => {
                            last_rejected => {
                                rejected_reasons => [map { $idv_rejected_reasons->{$_} } qw/UNDERAGE/],
                                document_type    => 'passport',
                                report_available => 1
                            },
                            poi_status => 'rejected',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, verified - ignore age verification",
                        latest_poi_by             => $latest_poi_by,
                        idv_last_updated_document => {
                            status          => 'verified',
                            status_messages => '[]',
                            document_type   => 'passport',
                        },
                        age_verification        => 1,
                        ignore_age_verification => 1,
                        expected_result         => {
                            last_rejected => {},
                            poi_status    => 'none',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, verified - no expiration date",
                        latest_poi_by             => $latest_poi_by,
                        idv_last_updated_document => {
                            status          => 'verified',
                            status_messages => '[]',
                            document_type   => 'passport',
                        },
                        age_verification => 1,
                        expected_result  => {
                            last_rejected => {},
                            poi_status    => 'verified',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, verified - non expired expiration date",
                        latest_poi_by             => $latest_poi_by,
                        age_verification          => 1,
                        idv_last_updated_document => {
                            status                   => 'verified',
                            status_messages          => '[]',
                            document_type            => 'passport',
                            document_expiration_date => $non_expired_date->date_yyyymmdd,
                        },
                        expected_result => {
                            last_rejected => {},
                            poi_status    => 'verified',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, verified - expired expiration date",
                        latest_poi_by             => $latest_poi_by,
                        age_verification          => 1,
                        idv_last_updated_document => {
                            status                   => 'verified',
                            status_messages          => '[]',
                            document_type            => 'passport',
                            document_expiration_date => $expired_date->date_yyyymmdd,
                        },
                        expected_result => {
                            last_rejected => {},
                            poi_status    => 'verified',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, high risk, verified - expired expiration date",
                        latest_poi_by             => $latest_poi_by,
                        age_verification          => 1,
                        ignore_age_verification   => 1,
                        idv_last_updated_document => {
                            status                   => 'verified',
                            status_messages          => '[]',
                            document_type            => 'passport',
                            document_expiration_date => $expired_date->date_yyyymmdd,
                        },
                        expected_result => {
                            last_rejected => {},
                            poi_status    => 'expired',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, pending",
                        latest_poi_by             => $latest_poi_by,
                        idv_last_updated_document => {
                            status          => 'pending',
                            status_messages => '["NAME_MISMATCH"]',
                            document_type   => 'passport',
                        },
                        expected_result => {
                            last_rejected => {},
                            poi_status    => 'pending',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, failed",
                        latest_poi_by             => $latest_poi_by,
                        idv_last_updated_document => {
                            status          => 'failed',
                            status_messages => '["EMPTY_STATUS"]',
                            document_type   => 'passport',
                        },
                        expected_result => {
                            last_rejected => {
                                rejected_reasons => [map { $idv_rejected_reasons->{$_} } qw/EMPTY_STATUS/],
                                document_type    => 'passport',
                                report_available => 1
                            },
                            poi_status => 'rejected',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, empty string for status messages",
                        latest_poi_by             => $latest_poi_by,
                        idv_last_updated_document => {
                            status          => 'failed',
                            status_messages => '',
                            document_type   => 'passport',
                        },
                        expected_result => {
                            last_rejected => {
                                rejected_reasons => [],
                                document_type    => 'passport',
                                report_available => 1
                            },
                            poi_status => 'rejected',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, undef elem in status messages",
                        latest_poi_by             => $latest_poi_by,
                        idv_last_updated_document => {
                            status          => 'failed',
                            status_messages => '[null]',
                            document_type   => 'passport',
                        },
                        expected_result => {
                            last_rejected => {
                                rejected_reasons => [],
                                document_type    => 'passport',
                                report_available => 1
                            },
                            poi_status => 'rejected',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, undef in status messages",
                        latest_poi_by             => $latest_poi_by,
                        idv_last_updated_document => {
                            status          => 'failed',
                            status_messages => undef,
                            document_type   => 'passport',
                        },
                        expected_result => {
                            last_rejected => {
                                rejected_reasons => [],
                                document_type    => 'passport',
                                report_available => 1
                            },
                            poi_status => 'rejected',
                        },
                    },
                    {
                        title                     => "Testing latest poi by: $latest_poi_by, report not available in status messages",
                        latest_poi_by             => $latest_poi_by,
                        idv_last_updated_document => {
                            status          => 'refuted',
                            status_messages => '["NAME_MISMATCH", "REPORT_UNAVAILABLE"]',
                            document_type   => 'passport',
                        },
                        expected_result => {
                            last_rejected => {
                                rejected_reasons => [map { $idv_rejected_reasons->{$_} } qw/NAME_MISMATCH/],
                                document_type    => 'passport',
                                report_available => 0
                            },
                            poi_status => 'rejected',
                        },
                    });

                for my $test_case ($test_cases->@*) {
                    $client_mock->mock(latest_poi_by           => $test_case->{latest_poi_by}           // 'none');
                    $client_mock->mock(ignore_age_verification => $test_case->{ignore_age_verification} // 0);

                    if ($test_case->{age_verification}) {
                        $status_mock->mock(
                            age_verification => +{
                                staff_name => 'mr cat boi',
                                reason     => 'test'
                            });
                    }

                    $idv_mock->mock(get_last_updated_document => $test_case->{idv_last_updated_document});

                    my $result = $c->tcall($method, {token => $token_cr});

                    my $title = $test_case->{title};

                    cmp_deeply($result->{identity}->{service}, $test_case->{latest_poi_by}, "expected poi_service for test: $title");

                    cmp_deeply($result->{identity}->{status}, $test_case->{expected_result}->{poi_status}, "expected poi_status for test: $title");

                    cmp_deeply(
                        $result->{identity}->{last_rejected},
                        $test_case->{expected_result}->{last_rejected},
                        "expected last_rejected for test: $title"
                    );

                    $client_cr->status->clear_age_verification;
                    $client_mock->unmock_all;
                    $status_mock->unmock_all;
                    $idv_mock->unmock_all;
                }
            };

            subtest 'latest_poi_by: onfido' => sub {
                my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'CR',
                });

                my $user_cr = BOM::User->create(
                    email    => 'kyc_latest_poi_by_onfido@deriv.com',
                    password => 'secret_pwd'
                );

                $user_cr->add_client($client_cr);

                my $client_mock = Test::MockModule->new('BOM::User::Client');
                # mocks latest_poi_by

                my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
                # mocks age_verification, poi mismatch, dob mismatch

                my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
                # mocks get_latest_check get_consider_reasons
                my $onfido_reject_reasons = BOM::Platform::Utility::rejected_onfido_reasons_error_codes();
                my $onfido_document_sub_result;
                my $onfido_check_result;

                my $token_cr = $m->create_token($client_cr->loginid, 'test token');

                my $test_cases = [];

                my $latest_poi_by = 'onfido';
                push $test_cases->@*, (
                    map {
                        +{
                            title                   => "Testing latest poi by: $latest_poi_by, $_",
                            latest_poi_by           => $latest_poi_by,
                            onfido_consider_reasons => [$_],
                            onfido_status           => 'rejected',
                            expected_result         => {
                                last_rejected => {rejected_reasons => [$onfido_reject_reasons->{$_}]},
                                poi_status    => 'rejected',
                            },
                        }
                    } keys $onfido_reject_reasons->%*
                );

                push $test_cases->@*,
                    ({
                        title                   => 'Not declared reasons are filtered out',
                        latest_poi_by           => $latest_poi_by,
                        onfido_consider_reasons => [qw/too much garbage/],
                        onfido_status           => 'suspected',
                        expected_result         => {
                            last_rejected => {
                                rejected_reasons => [],
                            },
                            poi_status => 'suspected',
                        },
                    },
                    {
                        title                   => 'Duplicated message is reported once',
                        latest_poi_by           => $latest_poi_by,
                        onfido_consider_reasons => ['data_comparison.first_name', 'data_comparison.last_name'],
                        onfido_status           => 'suspected',
                        expected_result         => {
                            last_rejected => {rejected_reasons => ['DataComparisonName']},
                            poi_status    => 'suspected',
                        },
                    },
                    {
                        title                   => 'Multiple messages reported',
                        latest_poi_by           => $latest_poi_by,
                        onfido_consider_reasons => ['data_comparison.first_name', 'age_validation.minimum_accepted_age', 'selfie', 'garbage'],
                        onfido_status           => 'suspected',
                        expected_result         => {
                            last_rejected => {rejected_reasons => ['DataComparisonName', 'AgeValidationMinimumAcceptedAge', 'SelfieRejected']},
                            poi_status    => 'suspected',
                        },
                    },
                    {
                        title                   => 'Name mismatch',
                        latest_poi_by           => $latest_poi_by,
                        poi_name_mismatch       => 1,
                        onfido_status           => 'rejected',
                        onfido_consider_reasons => [],
                        expected_result         => {
                            last_rejected => {rejected_reasons => ['DataComparisonName']},
                            poi_status    => 'rejected',
                        },
                    },
                    {
                        title                   => 'Date of birth mismatch',
                        latest_poi_by           => $latest_poi_by,
                        poi_dob_mismatch        => 1,
                        onfido_status           => 'rejected',
                        onfido_consider_reasons => [],
                        expected_result         => {
                            last_rejected => {rejected_reasons => ['DataComparisonDateOfBirth']},
                            poi_status    => 'rejected',
                        },
                    },
                    {
                        onfido_consider_reasons => ['data_comparison.first_name', 'age_validation.minimum_accepted_age', 'selfie', 'garbage'],
                        latest_poi_by           => $latest_poi_by,
                        title                   => 'Empty rejected messages for verified account',
                        onfido_status           => 'verified',
                        age_verification        => 1,
                        expected_result         => {
                            last_rejected => {},
                            poi_status    => 'verified',
                        },
                    },
                    );

                for my $test_case ($test_cases->@*) {
                    $client_mock->mock(latest_poi_by => $test_case->{latest_poi_by} // 'none');

                    if ($test_case->{age_verification}) {
                        $status_mock->mock(
                            age_verification => +{
                                staff_name => 'test',
                                reason     => 'test'
                            });
                    }
                    $status_mock->mock(poi_name_mismatch => $test_case->{poi_name_mismatch} // 0);
                    $status_mock->mock(poi_dob_mismatch  => $test_case->{poi_dob_mismatch}  // 0);

                    if ($test_case->{onfido_status} eq 'rejected') {
                        $onfido_document_sub_result = 'rejected';
                        $onfido_check_result        = 'consider';
                    } elsif ($test_case->{onfido_status} eq 'suspected') {
                        $onfido_document_sub_result = 'suspected';
                        $onfido_check_result        = 'consider';
                    } elsif ($test_case->{onfido_status} eq 'verified') {
                        $onfido_document_sub_result = undef;
                        $onfido_check_result        = 'clear';
                    }

                    $onfido_mock->mock(
                        get_latest_check => {
                            report_document_status     => 'complete',
                            report_document_sub_result => $onfido_document_sub_result,
                            user_check                 => {
                                result => $onfido_check_result,
                            },
                        });

                    $onfido_mock->mock(get_consider_reasons => $test_case->{onfido_consider_reasons});

                    my $result = $c->tcall($method, {token => $token_cr});

                    my $title = $test_case->{title};

                    cmp_deeply($result->{identity}->{service}, $test_case->{latest_poi_by}, "expected poi_service for test: $title");

                    cmp_deeply($result->{identity}->{status}, $test_case->{expected_result}->{poi_status}, "expected poi_status for test: $title");

                    cmp_deeply(
                        $result->{identity}->{last_rejected},
                        $test_case->{expected_result}->{last_rejected},
                        "expected last_rejected for test: $title"
                    );

                    $status_mock->unmock_all;
                    $onfido_mock->unmock_all;
                    $client_mock->unmock_all;
                }

                subtest 'duplicated accounts: onfido rejected' => sub {
                    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                        broker_code => 'CR',
                    });

                    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                        broker_code => 'VRTC',
                    });

                    my $user = BOM::User->create(
                        email    => 'kyc_dup_onfido_rejected@deriv.com',
                        password => 'secret_pwd'
                    );

                    $user->add_client($client_cr);
                    $user->add_client($client_vr);

                    my $token_cr = $m->create_token($client_cr->loginid, 'test token');
                    my $result   = $c->tcall($method, {token => $token_cr});

                    cmp_deeply $result->{identity}->{status}, 'none', 'initial poi status is none';

                    # make the account duplicated
                    $client_cr->status->set('duplicate_account', 'system', 'Duplicate account - currency change');

                    my $token_vr = $m->create_token($client_vr->loginid, 'virtual token');

                    $result = $c->tcall($method, {token => $token_vr});

                    cmp_deeply $result->{identity}->{status}, 'none', 'poi status is still none';

                    my $client_mock = Test::MockModule->new('BOM::User::Client');
                    $client_mock->mock(latest_poi_by => 'onfido');

                    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');

                    $onfido_mock->mock(
                        get_latest_check => {
                            report_document_status     => 'complete',
                            report_document_sub_result => 'rejected',
                            user_check                 => {
                                result => 'consider',
                            },
                        });

                    $result = $c->tcall($method, {token => $token_vr});

                    cmp_deeply $result->{identity}->{service}, 'onfido',   'poi service is onfido for duplicated account';
                    cmp_deeply $result->{identity}->{status},  'rejected', 'poi status is rejected for duplicated account';

                    $onfido_mock->unmock_all;
                    $client_mock->unmock_all;
                };
            };

            subtest 'latest_poi_by: manual' => sub {
                my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'CR',
                });

                my $user_cr = BOM::User->create(
                    email    => 'kyc_latest_poi_by_manual@deriv.com',
                    password => 'secret_pwd'
                );

                $user_cr->add_client($client_cr);

                my $client_mock = Test::MockModule->new('BOM::User::Client');
                # mocks latest_poi_by

                my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
                # mocks uploaded

                my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
                # mocks age_verification

                my $expired_date = Date::Utility->today->_minus_years(1);

                my $token_cr = $m->create_token($client_cr->loginid, 'test token');

                my $test_cases = [];

                my $latest_poi_by = 'manual';
                push $test_cases->@*,
                    ({
                        title              => "Testing latest poi by: $latest_poi_by, uploaded",
                        latest_poi_by      => $latest_poi_by,
                        documents_uploaded => {
                            proof_of_identity => {
                                is_pending => 1,
                                documents  => {
                                    test => {
                                        test => 1,
                                    }
                                },
                            },
                        },
                        expected_result => {
                            last_rejected => {},
                            poi_status    => 'pending',
                        },
                    },
                    {
                        title              => "Testing latest poi by: $latest_poi_by, expired",
                        latest_poi_by      => $latest_poi_by,
                        documents_uploaded => {
                            proof_of_identity => {
                                is_pending => 0,
                                is_expired => 1,
                                documents  => {
                                    test => {
                                        test => 1,
                                    }
                                },
                            },
                        },
                        expected_result => {
                            last_rejected => {},
                            poi_status    => 'expired',
                        },
                    },
                    {
                        title               => "Testing latest poi by: $latest_poi_by, expired, fully auth",
                        latest_poi_by       => $latest_poi_by,
                        fully_authenticated => 1,
                        documents_uploaded  => {
                            proof_of_identity => {
                                is_expired => 1,
                                documents  => {
                                    test => {
                                        test => 1,
                                    }
                                },
                            },
                        },
                        documents_expired => 1,
                        expected_result   => {
                            last_rejected => {},
                            poi_status    => 'expired',
                        },
                    },
                    {
                        title              => "Testing latest poi by: $latest_poi_by, expired, age verified",
                        latest_poi_by      => $latest_poi_by,
                        age_verification   => 1,
                        documents_uploaded => {
                            proof_of_identity => {
                                is_expired => 1,
                                documents  => {
                                    test => {
                                        test => 1,
                                    }
                                },
                            },
                        },
                        documents_expired => 1,
                        expected_result   => {
                            last_rejected => {},
                            poi_status    => 'expired',
                        },
                    },
                    {
                        title              => "Testing latest poi by: $latest_poi_by, rejected",
                        latest_poi_by      => $latest_poi_by,
                        documents_uploaded => {
                            proof_of_identity => {
                                is_pending  => 0,
                                is_expired  => 0,
                                is_verified => 0,
                                documents   => {
                                    test => {
                                        test => 1,
                                    }
                                },
                            },
                        },
                        expected_result => {
                            last_rejected => {rejected_reasons => []},
                            poi_status    => 'rejected',
                        },
                    },
                    {
                        title              => "Testing latest poi by: $latest_poi_by, verified",
                        latest_poi_by      => $latest_poi_by,
                        age_verification   => 1,
                        documents_uploaded => {
                            proof_of_identity => {
                                is_pending  => 0,
                                is_verified => 1,
                                documents   => {
                                    test => {
                                        test => 1,
                                    }
                                },
                            },
                        },
                        expected_result => {
                            last_rejected => {},
                            poi_status    => 'verified',
                        },
                    },
                    {
                        title            => "Testing latest poi by: $latest_poi_by, verified - no uploaded",
                        latest_poi_by    => $latest_poi_by,
                        age_verification => 1,
                        expected_result  => {
                            last_rejected => {},
                            poi_status    => 'verified',
                        },
                    },
                    );

                for my $test_case ($test_cases->@*) {
                    $client_mock->mock(latest_poi_by => $test_case->{latest_poi_by} // 'none');
                    $client_mock->redefine(fully_authenticated => $test_case->{fully_authenticated} // 0);

                    if ($test_case->{age_verification}) {
                        $status_mock->mock(
                            age_verification => +{
                                staff_name => 'mr cat boi',
                                reason     => 'test'
                            });
                    }

                    $documents_mock->mock(uploaded => $test_case->{documents_uploaded} // {});

                    $documents_mock->mock(expired => $test_case->{documents_expired} // 0);

                    my $result = $c->tcall($method, {token => $token_cr});

                    my $title = $test_case->{title};

                    cmp_deeply($result->{identity}->{service}, $test_case->{latest_poi_by}, "expected poi_service for test: $title");

                    cmp_deeply($result->{identity}->{status}, $test_case->{expected_result}->{poi_status}, "expected poi_status for test: $title");

                    cmp_deeply(
                        $result->{identity}->{last_rejected},
                        $test_case->{expected_result}->{last_rejected},
                        "expected last_rejected for test: $title"
                    );

                    $client_cr->status->clear_age_verification;
                    $client_mock->unmock_all;
                    $status_mock->unmock_all;
                    $documents_mock->unmock_all;
                }
            };
        };

        subtest 'POI flow tests' => sub {
            subtest 'idv verified -> high_risk -> manual pending' => sub {
                my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'CR',
                });

                my $user_cr = BOM::User->create(
                    email    => 'kyc_flow_1@deriv.com',
                    password => 'secret_pwd'
                );

                $user_cr->add_client($client_cr);

                my $client_mock = Test::MockModule->new('BOM::User::Client');
                # mocks latest_poi_by

                my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');
                # mocks get_last_updated_document

                my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
                # mocks uploaded

                $idv_mock->mock(
                    'get_last_updated_document',
                    sub {
                        return {
                            status => 'verified',
                        };
                    });

                my $latest_poi_by;
                $client_mock->mock(
                    'latest_poi_by',
                    sub {
                        return $latest_poi_by // 'none';
                    });

                my $documents_uploaded;
                $documents_mock->mock(
                    'uploaded',
                    sub {
                        return $documents_uploaded // {};
                    });

                $latest_poi_by = 'idv';
                $client_cr->status->set('age_verification', 'system', 'test');

                my $expected_response = {
                    last_rejected      => {},
                    available_services => ['manual'],
                    service            => 'idv',
                    status             => 'verified',
                };

                my $token_cr = $m->create_token($client_cr->loginid, 'test token');
                my $result   = $c->tcall($method, {token => $token_cr});
                cmp_deeply $result->{identity}, $expected_response, 'expected response object for idv verified';

                $client_cr->aml_risk_classification('high');
                $client_cr->save;

                $expected_response = {
                    last_rejected      => {},
                    available_services => ['onfido', 'manual'],
                    service            => 'idv',
                    status             => 'none',
                };

                $result = $c->tcall($method, {token => $token_cr});
                cmp_deeply $result->{identity}, $expected_response, 'expected response object for high risk client';

                $latest_poi_by      = 'manual';
                $documents_uploaded = {
                    proof_of_identity => {
                        is_pending => 1,
                        documents  => {
                            test => {
                                test => 1,
                            }}}};

                $expected_response = {
                    last_rejected      => {},
                    available_services => ['onfido', 'manual'],
                    service            => 'manual',
                    status             => 'pending',
                };

                $result = $c->tcall($method, {token => $token_cr});
                cmp_deeply $result->{identity}, $expected_response, 'expected response object for manual pending';

                $documents_uploaded = {
                    proof_of_identity => {
                        is_verified => 1,
                        documents   => {
                            test => {
                                test => 1,
                            }}}};

                my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
                $status_mock->mock(
                    age_verification => +{
                        staff_name => 'mr cat boi',
                        reason     => 'test'
                    });

                $expected_response = {
                    last_rejected      => {},
                    available_services => ['manual'],
                    service            => 'manual',
                    status             => 'verified',
                };

                $result = $c->tcall($method, {token => $token_cr});
                cmp_deeply $result->{identity}, $expected_response, 'expected response object for manual verified';

                $client_mock->unmock_all;
                $status_mock->unmock_all;
                $documents_mock->unmock_all;
                $idv_mock->unmock_all;
            };

            subtest 'idv rejected -> onfido verified' => sub {
                my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'CR',
                });

                my $user_cr = BOM::User->create(
                    email    => 'kyc_flow_2@deriv.com',
                    password => 'secret_pwd'
                );

                $user_cr->add_client($client_cr);

                my $client_mock = Test::MockModule->new('BOM::User::Client');
                $client_mock->mock(latest_poi_by => 'idv');

                my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');

                $idv_mock->mock(
                    get_last_updated_document => {
                        status          => 'refuted',
                        status_messages => '["NAME_MISMATCH"]',
                        document_type   => 'passport'
                    });
                $idv_mock->mock(submissions_left => 0);

                my $expected_response = {
                    last_rejected => {
                        rejected_reasons => ['NameMismatch'],
                        document_type    => 'passport',
                        report_available => 1
                    },
                    available_services => ['onfido', 'manual'],
                    service            => 'idv',
                    status             => 'rejected',
                };

                my $token_cr = $m->create_token($client_cr->loginid, 'test token');
                my $result   = $c->tcall($method, {token => $token_cr});
                cmp_deeply $result->{identity}, $expected_response, 'expected response object for idv rejected, no submissions left';

                $client_mock->mock(latest_poi_by => 'onfido');

                my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');

                $onfido_mock->mock(
                    get_latest_check => {
                        report_document_status     => 'complete',
                        report_document_sub_result => undef,
                        user_check                 => {
                            result => 'clear',
                        },
                    });
                $onfido_mock->mock(get_consider_reasons => []);

                my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
                $status_mock->mock(
                    age_verification => +{
                        staff_name => 'system',
                        reason     => 'test'
                    });

                $expected_response = {
                    last_rejected      => {},
                    available_services => ['manual'],
                    service            => 'onfido',
                    status             => 'verified',
                };

                $result = $c->tcall($method, {token => $token_cr});
                cmp_deeply $result->{identity}, $expected_response, 'expected response object for onfido verfied';

                $client_mock->unmock_all;
                $status_mock->unmock_all;
                $idv_mock->unmock_all;
                $onfido_mock->unmock_all;
            };

            subtest 'onfido suspected -> onfido verified' => sub {
                my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code => 'CR',
                });

                my $user_cr = BOM::User->create(
                    email    => 'kyc_flow_3@deriv.com',
                    password => 'secret_pwd'
                );

                $user_cr->add_client($client_cr);

                my $client_mock = Test::MockModule->new('BOM::User::Client');
                $client_mock->mock(latest_poi_by => 'onfido');

                my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');

                $onfido_mock->mock(
                    get_latest_check => {
                        report_document_status     => 'complete',
                        report_document_sub_result => 'suspected',
                        user_check                 => {
                            result => 'consider',
                        },
                    });
                $onfido_mock->mock(get_consider_reasons => ['data_comparison.first_name']);

                my $expected_response = {
                    last_rejected      => {rejected_reasons => ['DataComparisonName']},
                    available_services => ['idv', 'onfido', 'manual'],
                    service            => 'onfido',
                    status             => 'suspected',
                };

                my $token_cr = $m->create_token($client_cr->loginid, 'test token');
                my $result   = $c->tcall($method, {token => $token_cr});
                cmp_deeply $result->{identity}, $expected_response, 'expected response object for onfido rejected';

                $onfido_mock->mock(
                    get_latest_check => {
                        report_document_status     => 'complete',
                        report_document_sub_result => undef,
                        user_check                 => {
                            result => 'clear',
                        },
                    });

                $onfido_mock->mock(get_consider_reasons => []);

                my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
                $status_mock->mock(
                    age_verification => +{
                        staff_name => 'system',
                        reason     => 'test'
                    });

                $expected_response = {
                    last_rejected      => {},
                    available_services => ['manual'],
                    service            => 'onfido',
                    status             => 'verified',
                };

                $result = $c->tcall($method, {token => $token_cr});
                cmp_deeply $result->{identity}, $expected_response, 'expected response object for onfido verified to correct failed attempt';

                $client_mock->unmock_all;
                $status_mock->unmock_all;
                $onfido_mock->unmock_all;
            };
        };

        subtest 'many poi authentication methods' => sub {
            my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $user = BOM::User->create(
                email    => 'kyc_multiplemethods@deriv.com',
                password => 'secret_pwd'
            );

            $user->add_client($client_cr);

            $client_cr->db->dbic->run(
                fixup => sub {
                    my $sth = $_->prepare(
                        "INSERT INTO betonmarkets.client_authentication_method (client_loginid, authentication_method_code, status) VALUES (?,?,?)");
                    $sth->execute($client_cr->loginid, 'ID_ONLINE',   'pending');
                    $sth->execute($client_cr->loginid, 'IDV',         'pass');
                    $sth->execute($client_cr->loginid, 'ID_DOCUMENT', 'needs_review');
                });

            my $count_authentication_methods = $client_cr->db->dbic->run(
                fixup => sub {
                    $_->selectrow_hashref(
                        'SELECT count(*) FROM betonmarkets.client_authentication_method WHERE client_loginid=? GROUP BY client_loginid',
                        undef, $client_cr->loginid);
                });
            is($count_authentication_methods->{count}, 3, 'client has multiple authentication_methods');

            my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
            $status_mock->mock(
                age_verification => +{
                    staff_name         => 'mr cat',
                    reason             => 'test',
                    last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
                });

            ok $client_cr->fully_authenticated,      'Client is fully authenticated';
            ok $client_cr->status->age_verification, 'Age verified';

            my $token_cr = $m->create_token($client_cr->loginid, 'test token');
            my $result   = $c->tcall($method, {token => $token_cr});

            is $result->{identity}->{status}, 'verified', 'client is poi verified';

            $status_mock->unmock_all;
        };
    };
};

subtest 'kyc authorization status, landing companies provided as argument' => sub {

    subtest 'test 0' => sub {
        my $user_cr = BOM::User->create(
            email    => 'kyc_lc_test0@deriv.com',
            password => 'secret_pwd'
        );

        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $user_cr->add_client($client_cr);

        my $token_cr = $m->create_token($client_cr->loginid, 'test token');

        my $args   = {landing_companies => ['svg', 'maltainvest']};
        my $params = {
            token => $token_cr,
            args  => $args
        };

        my $result = $c->tcall($method, $params);
        is $result->{error}, undef, 'Call has no errors when landing company argument is provided';
    };

    subtest 'argument validations' => sub {
        subtest 'should ignore any invalid arguments and not throw' => sub {
            my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $user_cr = BOM::User->create(
                email    => 'kyc_lc_invalid_arg@deriv.com',
                password => 'secret_pwd'
            );

            $user_cr->add_client($client_cr);

            my $token_cr = $m->create_token($client_cr->loginid, 'test token');

            my $args   = {landing_companies => ['svg', 'big-cat', 'maltainvest', 'small-cat']};
            my $params = {
                token => $token_cr,
                args  => $args
            };

            my $expected_response = {
                svg => {
                    identity => {
                        status             => 'none',
                        service            => 'none',
                        last_rejected      => {},
                        available_services => ['idv', 'onfido', 'manual']
                    },
                    address => {status => 'none'},
                },
                maltainvest => {
                    identity => {
                        status             => 'none',
                        service            => 'none',
                        last_rejected      => {},
                        available_services => ['onfido', 'manual']
                    },
                    address => {status => 'none'}}};

            my $result = $c->tcall($method, $params);
            is $result->{error}, undef, 'call did not throw error for invalid arguments';
            cmp_deeply($result, $expected_response, 'expected response object for ignored invalid arguments');
        };

        subtest 'should fallback to standard response if all arguments are invalid' => sub {
            my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $user_cr = BOM::User->create(
                email    => 'kyc_lc_all_invalid_arg@deriv.com',
                password => 'secret_pwd'
            );

            $user_cr->add_client($client_cr);

            my $token_cr = $m->create_token($client_cr->loginid, 'test token');

            my $args   = {landing_companies => ['big-cat', 'small-cat', 'tiny-cat']};
            my $params = {
                token => $token_cr,
                args  => $args
            };

            my $expected_response = {
                identity => {
                    last_rejected      => {},
                    available_services => ['idv', 'onfido', 'manual'],
                    service            => 'none',
                    status             => 'none',
                },
                address => {
                    status => 'none',
                },
            };

            my $result = $c->tcall($method, $params);
            is $result->{error}, undef, 'call did not throw error for invalid arguments';
            cmp_deeply($result, $expected_response, 'expected response object for all invalid arguments');
        };

        subtest 'should take only unique arguments' => sub {
            my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $user_cr = BOM::User->create(
                email    => 'kyc_lc_uniq_arg@deriv.com',
                password => 'secret_pwd'
            );

            $user_cr->add_client($client_cr);

            my $token_cr = $m->create_token($client_cr->loginid, 'test token');

            my $args   = {landing_companies => ['svg', 'virtual', 'virtual', 'svg', 'virtual']};
            my $params = {
                token => $token_cr,
                args  => $args
            };

            my $expected_response = {
                svg => {
                    identity => {
                        status             => 'none',
                        service            => 'none',
                        last_rejected      => {},
                        available_services => ['idv', 'onfido', 'manual']
                    },
                    address => {status => 'none'},
                },
                virtual => {
                    identity => {
                        status             => 'none',
                        service            => 'none',
                        last_rejected      => {},
                        available_services => []
                    },
                    address => {status => 'none'}}};

            my $result = $c->tcall($method, $params);
            cmp_deeply($result, $expected_response, 'expected response object for repeated arguments');
        };

        subtest 'should limit amount of arguments to 20' => sub {
            my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $user_cr = BOM::User->create(
                email    => 'kyc_lc_20_arg@deriv.com',
                password => 'secret_pwd'
            );

            $user_cr->add_client($client_cr);

            my $token_cr = $m->create_token($client_cr->loginid, 'test token');

            my $lc_array_30 = [map { "lc$_" } 1 .. 30];

            my $args   = {landing_companies => $lc_array_30};
            my $params = {
                token => $token_cr,
                args  => $args
            };

            my $landing_company_mock = Test::MockModule->new('LandingCompany');
            my $counter              = 0;
            $landing_company_mock->mock(
                short => sub {
                    $counter++;
                    return $landing_company_mock->original('short')->(@_);
                });

            my $doc_mock = Test::MockModule->new('BOM::User::Client');
            $doc_mock->mock(
                'get_poa_status',
                sub {
                    return 'none';
                });

            my $result = $c->tcall($method, $params);

            my $n_landing_companies   = scalar LandingCompany::Registry->get_all;
            my $LCS_ARGUMENT_LIMIT    = 20;
            my $LCS_CALLS_AT_LAST_POI = 3;
            is $counter, $LCS_ARGUMENT_LIMIT * $n_landing_companies + $LCS_CALLS_AT_LAST_POI,
                'expected number of comparison in loop for arguments limited to 20 lcs';

            $landing_company_mock->unmock_all();
            $doc_mock->unmock_all;
        };
    };

    subtest 'landing company as argument is used over client\'s landing company' => sub {
        my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });

        my $user_vr = BOM::User->create(
            email    => 'kyc_lc_args_over_default@deriv.com',
            password => 'secret_pwd'
        );

        $user_vr->add_client($client_vr);

        my $token_vr = $m->create_token($client_vr->loginid, 'test token');

        my $args   = {landing_companies => ['svg', 'maltainvest']};
        my $params = {
            token => $token_vr,
            args  => $args
        };

        my $expected_response = {
            svg => {
                identity => {
                    status             => 'none',
                    service            => 'none',
                    last_rejected      => {},
                    available_services => ['idv', 'onfido', 'manual']
                },
                address => {status => 'none'},
            },
            maltainvest => {
                identity => {
                    status             => 'none',
                    service            => 'none',
                    last_rejected      => {},
                    available_services => ['onfido', 'manual']
                },
                address => {status => 'none'}}};

        my $result = $c->tcall($method, $params);
        cmp_deeply($result, $expected_response, 'expected response object for virtual client with provided lc arguments');
    };

    subtest 'returns correct information per landing companies\' configuration' => sub {
        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        my $user = BOM::User->create(
            email    => 'kyc_lc_many_lcs@deriv.com',
            password => 'secret_pwd'
        );

        $user->add_client($client_cr);

        my $token_cr = $m->create_token($client_cr->loginid, 'test token');

        my $args   = {landing_companies => ['virtual', 'svg', 'labuan', 'maltainvest']};
        my $params = {
            token => $token_cr,
            args  => $args
        };

        my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');
        $idv_mock->mock(
            get_last_updated_document => {
                id           => 1,
                status       => 'verified',
                requested_at => '2020-01-01 00:00:01',
                submitted_at => '2020-01-01 00:00:01'
            });

        my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
        $onfido_mock->mock(
            get_latest_check => {
                report_document_status     => 'complete',
                report_document_sub_result => 'suspected',
                user_check                 => {
                    result     => 'consider',
                    created_at => '2020-01-01 00:00:00'
                }});
        $onfido_mock->mock(get_consider_reasons => ['data_comparison.first_name']);

        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
        $status_mock->mock(
            age_verification => +{
                staff_name => 'system',
                reason     => 'test'
            });

        my $expected_response = {
            virtual => {
                identity => {
                    status             => 'none',
                    service            => 'none',
                    last_rejected      => {},
                    available_services => []
                },
                address => {status => 'none'}
            },
            svg => {
                identity => {
                    status             => 'verified',
                    service            => 'idv',
                    last_rejected      => {},
                    available_services => ['manual']
                },
                address => {status => 'none'},
            },
            labuan => {
                identity => {
                    status             => 'verified',
                    service            => 'idv',
                    last_rejected      => {},
                    available_services => ['manual']
                },
                address => {status => 'none'},
            },
            maltainvest => {
                identity => {
                    status             => 'suspected',
                    service            => 'onfido',
                    last_rejected      => {rejected_reasons => ['DataComparisonName']},
                    available_services => ['onfido', 'manual']
                },
                address => {status => 'none'}}};

        my $result = $c->tcall($method, $params);
        cmp_deeply $result, $expected_response, 'expected response object for many lcs as argument';

        $idv_mock->unmock_all;
        $onfido_mock->unmock_all;
        $status_mock->unmock_all;
    };
};

subtest 'kyc authorization status, country provided as argument' => sub {
    subtest 'test 0' => sub {
        my $user_cr = BOM::User->create(
            email    => 'kyc_country_test0@deriv.com',
            password => 'secret_pwd'
        );

        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $user_cr->add_client($client_cr);

        my $token_cr = $m->create_token($client_cr->loginid, 'test token');

        my $args   = {country => 'ke'};
        my $params = {
            token => $token_cr,
            args  => $args
        };

        my $result = $c->tcall($method, $params);
        is $result->{error}, undef, 'Call has no errors when country argument is provided';
    };

    subtest 'argument validations' => sub {
        subtest 'should handle invalid arguments and not throw' => sub {
            my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $user_cr = BOM::User->create(
                email    => 'kyc_country_invalid_arg@deriv.com',
                password => 'secret_pwd'
            );

            $user_cr->add_client($client_cr);

            my $token_cr = $m->create_token($client_cr->loginid, 'test token');

            my $args   = {country => 'xx'};
            my $params = {
                token => $token_cr,
                args  => $args
            };

            my $expected_response = {
                identity => {
                    status             => 'none',
                    service            => 'none',
                    last_rejected      => {},
                    available_services => []
                },
                address => {status => 'none'}};

            my $result = $c->tcall($method, $params);
            is $result->{error}, undef, 'call did not throw error for invalid arguments';
            cmp_deeply($result, $expected_response, 'expected response object for invalid argument');
        };
    };

    subtest 'should show supported documents only for the relevant available services' => sub {
        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        my $user_cr = BOM::User->create(
            email    => 'kyc_poi_supported_documents@deriv.com',
            password => 'secret_pwd'
        );

        $user_cr->add_client($client_cr);

        my $token_cr = $m->create_token($client_cr->loginid, 'test token');

        my $accounts_mock = Test::MockModule->new('BOM::RPC::v3::Accounts');

        my $format = '^123$';

        my $idv_mock                = Test::MockModule->new('BOM::User::IdentityVerification');
        my $idv_supported_documents = {
            national_id => {
                display_name => 'National ID Number',
                format       => $format,
            }};

        my $onfido_mock                = Test::MockModule->new('BOM::User::Onfido');
        my $onfido_supported_documents = {
            passport => {
                display_name => 'Passport',
                format       => $format,
            }};

        my $test_cases = [{
                available_services           => ['idv', 'onfido', 'manual'],
                expected_supported_documents => {
                    idv    => $idv_supported_documents,
                    onfido => $onfido_supported_documents
                }
            },
            {
                available_services           => ['onfido', 'manual'],
                expected_supported_documents => {onfido => $onfido_supported_documents}
            },
            {
                available_services           => ['idv', 'manual'],
                expected_supported_documents => {idv => $idv_supported_documents}
            },
            {
                available_services           => ['idv', 'onfido'],
                expected_supported_documents => {
                    idv    => $idv_supported_documents,
                    onfido => $onfido_supported_documents
                }
            },
            {
                available_services           => ['idv'],
                expected_supported_documents => {
                    idv => $idv_supported_documents,
                }
            },
            {
                available_services           => ['onfido'],
                expected_supported_documents => {
                    onfido => $onfido_supported_documents,
                }
            },
            {
                available_services           => ['manual'],
                expected_supported_documents => undef
            },
        ];

        my $args   = {country => 'ke'};
        my $params = {
            token => $token_cr,
            args  => $args
        };

        for my $test_case ($test_cases->@*) {
            $accounts_mock->mock(_get_available_services => $test_case->{available_services});
            $idv_mock->mock(supported_documents => $idv_supported_documents);
            $onfido_mock->mock(supported_documents => $onfido_supported_documents);

            my $result = $c->tcall($method, $params);

            cmp_deeply($result->{identity}->{supported_documents}, $test_case->{expected_supported_documents}, 'expected supported documents');
        }

        $accounts_mock->unmock_all;
        $idv_mock->unmock_all;
        $onfido_mock->unmock_all;
    };

    subtest 'returns correct information per countries\' configuration' => sub {
        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        my $user_cr = BOM::User->create(
            email    => 'kyc_correct_countries@deriv.com',
            password => 'secret_pwd'
        );

        $user_cr->add_client($client_cr);

        my $token_cr = $m->create_token($client_cr->loginid, 'test token');

        my $accounts_mock = Test::MockModule->new('BOM::RPC::v3::Accounts');

        my $args   = {country => 'ke'};
        my $params = {
            token => $token_cr,
            args  => $args
        };

        my $expected_response = {
            address  => {status => 'none'},
            identity => {
                service             => 'none',
                supported_documents => {
                    onfido => {
                        passport               => {display_name => 'Passport'},
                        national_identity_card => {display_name => 'National Identity Card'},
                        driving_licence        => {display_name => 'Driving Licence'}
                    },
                    idv => {
                        national_id => {
                            display_name => 'National ID Number',
                            format       => '^[0-9]{1,9}$'
                        },
                        passport => {
                            display_name => 'Passport',
                            format       => '^[A-Z0-9]{7,9}$'
                        },
                        alien_card => {
                            format       => '^[0-9]{6,9}$',
                            display_name => 'Alien Card'
                        }}
                },
                last_rejected      => {},
                available_services => ['idv', 'onfido', 'manual'],
                status             => 'none'
            }};

        my $result = $c->tcall($method, $params);
        cmp_deeply $result, $expected_response, 'expected response object';
    };
};

subtest 'kyc authorization status, country and landing companies provided as argument' => sub {
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $user = BOM::User->create(
        email    => 'kyc_many_args@deriv.com',
        password => 'secret_pwd'
    );

    $user->add_client($client_cr);

    my $token_cr = $m->create_token($client_cr->loginid, 'test token');

    my $args = {
        landing_companies => ['virtual', 'svg', 'maltainvest'],
        country           => 'ar'
    };
    my $params = {
        token => $token_cr,
        args  => $args
    };

    my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');
    $idv_mock->mock(
        get_last_updated_document => {
            id           => 1,
            status       => 'pending',
            requested_at => '2020-01-01 00:00:01',
            submitted_at => '2020-01-01 00:00:01'
        });

    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    $onfido_mock->mock(
        get_latest_check => {
            report_document_status     => 'complete',
            report_document_sub_result => 'suspected',
            user_check                 => {
                result     => 'consider',
                created_at => '2020-01-01 00:00:00'
            }});
    $onfido_mock->mock(get_consider_reasons => ['data_comparison.first_name']);

    my $expected_response = {
        virtual => {
            identity => {
                status             => 'none',
                service            => 'none',
                last_rejected      => {},
                available_services => []
            },
            address => {status => 'none'}
        },
        svg => {
            identity => {
                status              => 'pending',
                service             => 'idv',
                supported_documents => {
                    onfido => {
                        driving_licence        => {display_name => 'Driving Licence'},
                        passport               => {display_name => 'Passport'},
                        national_identity_card => {display_name => 'National Identity Card'},
                        residence_permit       => {display_name => 'Residence Permit'}
                    },
                    idv => {
                        dni => {
                            format       => '^\\d{7,8}$',
                            display_name => 'Documento Nacional de Identidad'
                        }}
                },
                last_rejected      => {},
                available_services => ['idv', 'onfido', 'manual']
            },
            address => {status => 'none'},
        },
        maltainvest => {
            identity => {
                status              => 'suspected',
                service             => 'onfido',
                supported_documents => {
                    onfido => {
                        driving_licence        => {display_name => 'Driving Licence'},
                        passport               => {display_name => 'Passport'},
                        national_identity_card => {display_name => 'National Identity Card'},
                        residence_permit       => {display_name => 'Residence Permit'}}
                },
                last_rejected      => {rejected_reasons => ['DataComparisonName']},
                available_services => ['onfido', 'manual']
            },
            address => {status => 'none'}}};

    my $result = $c->tcall($method, $params);
    cmp_deeply $result, $expected_response, 'expected response object for lcs and country as argument';

    $idv_mock->unmock_all;
    $onfido_mock->unmock_all;

    subtest 'garbage inputs' => sub {
        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        my $user = BOM::User->create(
            email    => 'kyc_garbage_inputs@deriv.com',
            password => 'secret_pwd'
        );

        $user->add_client($client_cr);

        my $token_cr = $m->create_token($client_cr->loginid, 'test token');

        my $args = {
            landing_companies => ['svg', 'big cat', 'maltainvest'],
            country           => 'xx'
        };
        my $params = {
            token => $token_cr,
            args  => $args
        };

        my $result            = $c->tcall($method, $params);
        my $expected_response = {
            maltainvest => {
                address  => {status => 'none'},
                identity => {
                    available_services => [],
                    service            => 'none',
                    last_rejected      => {},
                    status             => 'none'
                }
            },
            svg => {
                identity => {
                    status             => 'none',
                    last_rejected      => {},
                    service            => 'none',
                    available_services => []
                },
                address => {status => 'none'}}};

        cmp_deeply $result, $expected_response, 'expected response object for garbage inputs';
    };
};

done_testing();
