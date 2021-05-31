use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use List::Util;
use Encode;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use Encode qw(encode);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;
use BOM::Platform::Token::API;
use BOM::User::Password;
use BOM::User;
use BOM::User::Onfido;
use BOM::Test::Helper::Token;
use Test::BOM::RPC::QueueClient;

use BOM::Config::Redis;

BOM::Test::Helper::Token::cleanup_redis_tokens();

my $onfido_limit = BOM::User::Onfido::limit_per_user;
my $email        = 'abc@binary.com';
my $password     = 'jskjd8292922';
my $hash_pwd     = BOM::User::Password::hashpw($password);
my $test_client  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client->email($email);
$test_client->save;

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);
$user->add_client($test_client_vr);

my $test_client_cr_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});

$test_client_cr_vr->email('sample@binary.com');
$test_client_cr_vr->save;

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    citizen     => 'at',
});
$test_client_cr->email('sample@binary.com');
$test_client_cr->set_default_account('USD');
$test_client_cr->save;

my $test_client_cr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client_cr_2->email('sample@binary.com');
$test_client_cr_2->save;

my $user_cr = BOM::User->create(
    email    => 'sample@binary.com',
    password => $hash_pwd
);

$user_cr->add_client($test_client_cr_vr);
$user_cr->add_client($test_client_cr);
$user_cr->add_client($test_client_cr_2);

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_disabled->status->set('disabled', 1, 'test disabled');

my $email_mx       = 'mx@binary.com';
my $test_client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
    citizen     => ''
});
$test_client_mx->email($email_mx);

my $user_mx = BOM::User->create(
    email    => $email_mx,
    password => $hash_pwd
);
$user_mx->add_client($test_client_mx);

my $test_client_vr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr_2->email($email);
$test_client_vr_2->set_default_account('USD');
$test_client_vr_2->save;

my $email_mlt_mf    = 'mltmf@binary.com';
my $test_client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    residence   => 'at',
});
$test_client_mlt->email($email_mlt_mf);
$test_client_mlt->set_default_account('EUR');
$test_client_mlt->save;

my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    residence   => 'at',
});
$test_client_mf->email($email_mlt_mf);
$test_client_mf->save;

my $user_mlt_mf = BOM::User->create(
    email    => $email_mlt_mf,
    password => $hash_pwd
);
$user_mlt_mf->add_client($test_client_vr_2);
$user_mlt_mf->add_client($test_client_mlt);
$user_mlt_mf->add_client($test_client_mf);

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_client->loginid,          'test token');
my $token_vr       = $m->create_token($test_client_cr_vr->loginid,    'test token');
my $token_cr       = $m->create_token($test_client_cr->loginid,       'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_mx       = $m->create_token($test_client_mx->loginid,       'test token');
my $token_mlt      = $m->create_token($test_client_mlt->loginid,      'test token');

my $c = Test::BOM::RPC::QueueClient->new();

my $method = 'get_account_status';
subtest 'get account status' => sub {
    subtest "account generic" => sub {

        subtest 'cashier statuses' => sub {
            my $mocked_cashier_validation = Test::MockModule->new("BOM::Platform::Client::CashierValidation");

            my $result = $c->tcall('get_account_status', {token => $token_vr});
            cmp_deeply(
                $result->{status},
                ['cashier_locked', 'financial_information_not_complete', 'trading_experience_not_complete', 'trading_password_required'],
                "cashier is locked for virtual accounts"
            );

            $mocked_cashier_validation->mock('base_validation', {error => 1});
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                ['cashier_locked', 'financial_information_not_complete', 'trading_experience_not_complete', 'trading_password_required'],
                "cashier is locked correctly."
            );

            $mocked_cashier_validation->mock('base_validation', {});
            $result = $c->tcall('get_account_status', {token => $token_cr});

            cmp_deeply(
                $result->{status},
                ['financial_information_not_complete', 'trading_experience_not_complete', 'trading_password_required'],
                "cashier is not locked for correctly"
            );

            $mocked_cashier_validation->mock('withdraw_validation', {error => 1});
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                ['financial_information_not_complete', 'trading_experience_not_complete', 'trading_password_required', 'withdrawal_locked'],
                "withdrawal is locked correctly"
            );

            $mocked_cashier_validation->mock('withdraw_validation', {});
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                ['financial_information_not_complete', 'trading_experience_not_complete', 'trading_password_required'],
                "withdrawal is not locked correctly"
            );

            $mocked_cashier_validation->mock('deposit_validation', {error => 1});
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                ['deposit_locked', 'financial_information_not_complete', 'trading_experience_not_complete', 'trading_password_required'],
                "deposit is not locked correctly"
            );

            $mocked_cashier_validation->mock('deposit_validation', {});
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                ['financial_information_not_complete', 'trading_experience_not_complete', 'trading_password_required'],
                "deposit is not locked correctly"
            );

            $mocked_cashier_validation->unmock_all();
        };

        subtest 'validations' => sub {
            is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
            is(
                $c->tcall(
                    $method,
                    {
                        token => undef,
                    }
                )->{error}{message_to_client},
                'The token is invalid.',
                'invalid token error'
            );
            isnt(
                $c->tcall(
                    $method,
                    {
                        token => $token,
                    }
                )->{error}{message_to_client},
                'The token is invalid.',
                'no token error if token is valid'
            );
            is(
                $c->tcall(
                    $method,
                    {
                        token => $token_disabled,
                    }
                )->{error}{message_to_client},
                'This account is unavailable.',
                'check authorization'
            );

        };

        subtest 'maltainvest account' => sub {
            # test 'financial_assessment_not_complete'
            my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();

            # function to repeatedly test financial assessment
            sub test_financial_assessment {
                my ($data, $is_present, $msg) = @_;
                $test_client->financial_assessment({
                    data => encode_json_utf8($data),
                });
                $test_client->save();
                my $res = ((grep { $_ eq 'financial_assessment_not_complete' } @{$c->tcall($method, {token => $token})->{status}}) == $is_present);

                ok($res, $msg);
            }

            # 'financial_assessment_not_complete' should not present when everything is complete
            test_financial_assessment($data, 0, 'financial_assessment_not_complete should not be present when questions are answered properly');

            # When some questions are not answered
            delete $data->{account_turnover};
            test_financial_assessment($data, 1, 'financial_assessment_not_complete should present when questions are not answered');

            # When some answers are empty
            $data->{account_turnover} = "";
            test_financial_assessment($data, 1, 'financial_assessment_not_complete should be present when some answers are empty');

            # When the client's risk classification is different
            $test_client->aml_risk_classification('high');
            $test_client->save();
            test_financial_assessment($data, 1, "financial_assessment_not_complete should present regardless of the client's risk classification");
            # duplicate_account is not supposed to be shown to the users
            $test_client->status->set('duplicate_account');
            my $result = $c->tcall($method, {token => $token_cr});

            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "USD" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => noneof(qw(duplicate_account)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => [],
                    }
                },
                'duplicate_account is not in the status'
            );

            $test_client->status->clear_duplicate_account;

            # reset the risk classification for the following test
            $test_client->aml_risk_classification('low');
            $test_client->save();

            $result = $c->tcall($method, {token => $token});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "EUR" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => noneof(qw(authenticated)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => ["document", "identity"],
                    },
                    cashier_validation => ['ASK_AUTHENTICATE', 'ASK_CURRENCY', 'ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'],
                },
                'prompt for non authenticated MF client'
            );

            $test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
            $test_client->status->set("professional");
            $test_client->save;

            $result = $c->tcall($method, {token => $token});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "EUR" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(authenticated)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "verified",
                        },
                        identity => {
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => [],
                    },
                    cashier_validation => ['ASK_CURRENCY', 'ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'],
                },
                'authenticated, no deposits so it will not prompt for authentication'
            );

            my $mocked_client = Test::MockModule->new(ref($test_client));
            $mocked_client->mock('get_poi_status', sub { return 'expired' });
            $result = $c->tcall($method, {token => $token});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "EUR" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(document_expired)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "verified",
                        },
                        identity => {
                            status   => "expired",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => ['identity'],
                    },
                    cashier_validation => ['ASK_CURRENCY', 'ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'],
                },
                'correct account status returned for document expired, please note that this test for status key, authentication expiry structure is tested later'
            );

            $mocked_client->mock('get_poi_status', sub { return 'verified' });
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_identity => {
                            documents => {
                                $test_client->loginid
                                    . '_passport' => {
                                    expiry_date => Date::Utility->new->minus_time_interval('10d')->epoch,
                                    type        => 'passport',
                                    format      => 'pdf',
                                    id          => 2,
                                    status      => 'verified'
                                    },
                            },
                            expiry_date => Date::Utility->new->plus_time_interval('1d')->epoch,
                            is_expired  => 0,
                        },
                    };
                });
            $result = $c->tcall($method, {token => $token});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "EUR" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(document_expiring_soon)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "verified",
                        },
                        identity => {
                            status      => "verified",
                            expiry_date => Date::Utility->new->plus_time_interval('1d')->epoch,
                            services    => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => [],
                    },
                    cashier_validation => ['ASK_CURRENCY', 'ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'],
                },
                'correct account status returned for document expiring in next month'
            );

            $mocked_client->unmock('get_poi_status');
            $mocked_client->unmock('documents_uploaded');

            subtest "Age verified client, check for expiry of documents" => sub {
                # For age verified clients
                # we will only check for iom and malta. (expiry of documents)

                $test_client->set_authentication('ID_DOCUMENT', {status => 'pending'});
                $test_client->save;

                my $mocked_status = Test::MockModule->new(ref($test_client->status));
                $mocked_status->mock('age_verification', sub { return 1 });
                $mocked_client->mock(
                    'documents_uploaded',
                    sub {
                        return {
                            proof_of_identity => {
                                documents => {
                                    $test_client->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('10d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 2,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                        };
                    });

                my $documents              = $test_client->documents_uploaded();
                my $is_poi_already_expired = $documents->{proof_of_identity}->{is_expired};
                ok !$test_client->fully_authenticated, 'Not fully authenticated';
                ok $test_client->status->age_verification, 'Age verified';
                ok $is_poi_already_expired, 'POI expired';
                $result = $c->tcall($method, {token => $token_mx});

                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "GBP" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status                        => superbagof(qw(allow_document_upload document_expired)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '1',
                        authentication                => {
                            document => {
                                status => "none",
                            },
                            identity => {
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => [
                                            'Asylum Registration Card',
                                            'Certificate of Naturalisation',
                                            'Driving Licence',
                                            'Home Office Letter',
                                            'Immigration Status Document',
                                            'Passport',
                                            'Residence Permit',
                                            'Visa'
                                        ],
                                        country_code        => 'GBR',
                                        reported_properties => {},
                                    }}
                            },
                            needs_verification => superbagof(qw(identity)),
                        },
                        cashier_validation => ['ASK_CURRENCY', 'ASK_UK_FUNDS_PROTECTION'],
                    },
                    "authentication object is correct"
                );

                $mocked_client->unmock_all();
                $mocked_status->unmock_all();
            };
        };

        subtest 'costarica account' => sub {
            my $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "USD" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status              => [qw(financial_information_not_complete trading_experience_not_complete trading_password_required)],
                    risk_classification => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => [],
                    }
                },
                'Intial CR status is correct'
            );

            $test_client_cr->status->set('withdrawal_locked', 'system', 'For test purposes');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "USD" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(allow_document_upload withdrawal_locked)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => [],
                    }
                },
                'allow_document_upload is automatically added along with withdrawal_locked'
            );

            $test_client_cr->status->clear_withdrawal_locked;

            # unwelcome + false name
            $test_client_cr->status->set('unwelcome', 'system', 'For test purposes');
            cmp_deeply(
                $c->tcall($method, {token => $token_cr})->{status},
                superbagof(qw(unwelcome)),
                'allow_document_upload is not added along with unwelcome'
            );

            my $mocked_client = Test::MockModule->new(ref($test_client_cr));
            $mocked_client->mock(locked_for_false_profile_info => sub { return 1 });
            cmp_deeply(
                $c->tcall($method, {token => $token_cr})->{status},
                superbagof(qw(unwelcome allow_document_upload)),
                'allow_document_upload is automatically added along with unwelcome if account is locked for false name'
            );

            $test_client_cr->status->clear_unwelcome;
            $mocked_client->unmock('locked_for_false_profile_info');

            $test_client_cr->set_authentication('ID_DOCUMENT', {status => 'needs_action'});
            $test_client_cr->save;
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "USD" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(document_needs_action)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => ["document", "identity"],
                    }
                },
                'authentication page for POI and POA should be shown if the client is not age verified and needs action is set regardless of balance'
            );

            my $mocked_status = Test::MockModule->new(ref($test_client_cr->status));
            $mocked_status->mock('age_verification', sub { return 1 });
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "USD" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(document_needs_action)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => ["document"],
                    }
                },
                'authentication page should be shown for proof of address if needs action is set for age verified clients'
            );
            $mocked_status->unmock_all();

            subtest "Age verified client, do check for expiry of documents" => sub {
                # For age verified clients
                # we don't need to have a check for expiry of documents for svg

                my $mocked_client = Test::MockModule->new(ref($test_client_cr));
                $mocked_status->mock('age_verification', sub { return 1 });
                $mocked_client->mock(
                    'documents_uploaded',
                    sub {
                        return {
                            proof_of_identity => {
                                documents => {
                                    $test_client_cr->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 2,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                        };
                    });

                $mocked_client->mock('documents_expired', sub { return 1 });
                $test_client_cr->set_authentication('ID_DOCUMENT', {status => 'pending'});
                $test_client_cr->save;
                my $documents              = $test_client_cr->documents_uploaded();
                my $is_poi_already_expired = $documents->{proof_of_identity}->{is_expired};
                ok !$test_client_cr->fully_authenticated, 'Not fully authenticated';
                ok $test_client_cr->status->age_verification, 'Age verified';
                ok $is_poi_already_expired, 'POI expired';
                $result = $c->tcall($method, {token => $token_cr});

                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "USD" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status                        => noneof(qw(document_expired)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
                            document => {
                                status => "none",
                            },
                            identity => {
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                    }}
                            },
                            needs_verification => ['identity'],
                        }
                    },
                    "authentication object is correct"
                );

                $mocked_client->unmock_all();
                $mocked_status->unmock_all();
            };

            subtest 'Fully authenticated CR have to check for expired documents' => sub {
                my $mocked_client = Test::MockModule->new(ref($test_client_cr));
                $mocked_client->mock('fully_authenticated', sub { return 1 });
                $mocked_status->mock('age_verification',    sub { return 1 });
                $mocked_client->mock('documents_expired',   sub { return 1 });
                $mocked_client->mock(
                    'documents_uploaded',
                    sub {
                        return {
                            proof_of_address => {
                                documents => {
                                    $test_client_cr->loginid
                                        . '_bankstatement' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'bankstatement',
                                        format      => 'pdf',
                                        id          => 1,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                            proof_of_identity => {
                                documents => {
                                    $test_client_cr->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 2,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                        };
                    });

                ok $test_client_cr->documents_expired(), 'Client expiry is required';
                ok $test_client_cr->fully_authenticated, 'Account is fully authenticated';
                $result = $c->tcall($method, {token => $token_cr});

                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "USD" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status                        => superbagof(qw(allow_document_upload)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
                            document => {
                                status => "verified",
                            },
                            identity => {
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                    }}
                            },
                            needs_verification => ['identity'],
                        }
                    },
                    "authentication object is correct"
                );
                $mocked_client->unmock_all;
                $mocked_status->unmock_all;
            };

            $test_client_cr->get_authentication('ID_DOCUMENT')->delete;

            $test_client_cr->aml_risk_classification('high');
            $test_client_cr->save;
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "USD" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status => superbagof(qw(financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)),
                    risk_classification           => 'high',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => ["document", "identity"],
                    },
                },
                'ask for documents for unauthenticated client marked as high risk'
            );

            # Revert under review state
            $test_client_cr->aml_risk_classification('low');
            $test_client_cr->save;

            $test_client_cr->status->set('age_verification', 'system', 'age verified');
            $test_client_cr->status->setnx('allow_document_upload', 'system', 1);
            $test_client_cr->save;
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "USD" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(age_verification allow_document_upload)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => [],
                    }
                },
                'allow_document_upload flag is set if client is not authenticated and status exists on client'
            );

            # mark as fully authenticated
            $mocked_client->mock('fully_authenticated', sub { return 1 });

            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "USD" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status => superbagof(qw(age_verification authenticated financial_information_not_complete trading_experience_not_complete)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "verified",
                        },
                        identity => {
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => [],
                    }
                },
                'allow_document_upload flag is not send back if client is authenticated and even if status exists on client'
            );

            $mocked_status->unmock_all;
            $mocked_client->unmock_all;

            $test_client_cr->status->clear_age_verification();
            $test_client_cr->status->clear_allow_document_upload();
            $test_client_cr->save;

            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "USD" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw()),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => [],
                    }
                },
                'test if all manual status has been removed'
            );

        };

        subtest 'futher resubmission allowed' => sub {
            my $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply $result->{authentication}->{needs_verification}, noneof(qw/document identity/), 'Make sure needs verification is empty';
            cmp_deeply $result->{status}, noneof(qw/allow_document_upload/), 'Make sure allow_document_upload is off';

            subtest 'poi resubmission' => sub {
                $test_client_cr->status->set('allow_poi_resubmission', 'test', 'test');
                my $result = $c->tcall($method, {token => $token_cr});
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "USD" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status                        => superbagof(),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
                            document => {
                                status => "none",
                            },
                            identity => {
                                status   => "none",
                                services => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                    }}
                            },
                            needs_verification => superbagof(qw(identity)),
                        }
                    },
                );

                $test_client_cr->status->clear_allow_poi_resubmission;
            };

            subtest 'poa resubmission' => sub {
                $test_client_cr->status->set('allow_poa_resubmission', 'test', 'test');
                my $result = $c->tcall($method, {token => $token_cr});

                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "USD" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status                        => superbagof(),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
                            document => {
                                status => "none",
                            },
                            identity => {
                                status   => "none",
                                services => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                    }}
                            },
                            needs_verification => superbagof(qw(document))}
                    },
                );

                $test_client_cr->status->clear_allow_poa_resubmission;
            };
        };

        subtest 'malta account' => sub {
            $test_client_mlt->aml_risk_classification('high');
            $test_client_mlt->save;

            my $result = $c->tcall($method, {token => $token_mlt});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "EUR" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status => superbagof(
                        qw(allow_document_upload financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)
                    ),
                    risk_classification           => 'high',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit', 'Visa'],
                                    country_code         => 'AUT',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => ["document", "identity"],
                    },
                },
                'ask for documents for client marked as high risk'
            );

            $test_client_mlt->aml_risk_classification('low');
            $test_client_mlt->save;

            $result = $c->tcall($method, {token => $token_mlt});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "EUR" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status              => superbagof(qw(allow_document_upload financial_information_not_complete trading_experience_not_complete)),
                    risk_classification => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit', 'Visa'],
                                    country_code         => 'AUT',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => [],
                    },
                },
                'no prompt for malta client if first deposit is pending'
            );

            my $mocked_client = Test::MockModule->new(ref($test_client_mlt));
            $mocked_client->mock('has_deposits', sub { return 1 });

            $result = $c->tcall($method, {token => $token_mlt});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "EUR" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(financial_information_not_complete trading_experience_not_complete)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit', 'Visa'],
                                    country_code         => 'AUT',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => ["document", "identity"],
                    },
                },
                'ask for documents for malta client if first deposit has been done and not authorized'
            );
            $mocked_client->unmock_all;

            subtest "Age verified client, check for expiry of documents" => sub {
                # For age verified clients
                # we will only check for iom and malta. (expiry of documents)

                $test_client_mlt->set_authentication('ID_DOCUMENT', {status => 'pending'});
                $test_client_mlt->save;

                my $mocked_status = Test::MockModule->new(ref($test_client_mlt->status));
                $mocked_status->mock('age_verification',  sub { return 1 });
                $mocked_client->mock('documents_expired', sub { return 1 });
                $mocked_client->mock('has_deposits',      sub { return 1 });
                $mocked_client->mock(
                    'documents_uploaded',
                    sub {
                        return {
                            proof_of_identity => {
                                documents => {
                                    $test_client_mlt->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('10d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 2,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                        };
                    });

                my $documents              = $test_client_mlt->documents_uploaded();
                my $is_poi_already_expired = $documents->{proof_of_identity}->{is_expired};
                ok !$test_client_mlt->fully_authenticated, 'Not fully authenticated';
                ok $test_client_mlt->status->age_verification, 'Age verified';
                ok $is_poi_already_expired, 'POI expired';
                $result = $c->tcall($method, {token => $token_mlt});
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "EUR" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status                        => superbagof(qw(allow_document_upload document_expired)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '1',
                        authentication                => {
                            document => {
                                status => "none",
                            },
                            identity => {
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit', 'Visa'],
                                        country_code         => 'AUT',
                                        reported_properties  => {},
                                    }}
                            },
                            needs_verification => superbagof(qw(identity)),
                        }
                    },
                    "authentication object is correct"
                );

                $mocked_client->unmock_all();
                $mocked_status->unmock_all();
            };
        };

        subtest 'iom account' => sub {
            $test_client_mx->aml_risk_classification('high');
            $test_client_mx->save;

            my $result = $c->tcall($method, {token => $token_mx});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "GBP" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status => superbagof(qw(financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)),
                    risk_classification           => 'high',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Certificate of Naturalisation',
                                        'Driving Licence',
                                        'Home Office Letter',
                                        'Immigration Status Document',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'GBR',
                                    reported_properties => {},
                                }}
                        },
                        needs_verification => ["document", "identity"],
                    },
                    cashier_validation => ignore(),
                },
                'ask for documents for client marked as high risk'
            );

            $test_client_mx->aml_risk_classification('low');
            $test_client_mx->save;

            my $mocked_client = Test::MockModule->new(ref($test_client_mx));
            $mocked_client->mock('is_first_deposit_pending', sub { return 0 });

            my $mocked_status = Test::MockModule->new(ref($test_client_mx->status));
            $mocked_status->mock('age_verification', sub { return {reason => 'test reason'} });
            $mocked_status->mock('unwelcome',        sub { return {reason => 'test reason'} });

            $result = $c->tcall($method, {token => $token_mx});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "GBP" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(financial_information_not_complete trading_experience_not_complete)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Certificate of Naturalisation',
                                        'Driving Licence',
                                        'Home Office Letter',
                                        'Immigration Status Document',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'GBR',
                                    reported_properties => {},
                                }}
                        },
                        needs_verification => ["document"],
                    },
                    cashier_validation => ignore(),
                },
                'ask for proof of address and proof of identity documents for iom client if age verified and not fully authenticated client is marked as unwelcome'
            );

            # mark as fully authenticated
            $test_client_mx->set_authentication('ID_DOCUMENT', {status => 'pass'});
            $test_client_mx->save;
            $result = $c->tcall($method, {token => $token_mx});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "GBP" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(financial_information_not_complete trading_experience_not_complete)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status => "verified",
                        },
                        identity => {
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Certificate of Naturalisation',
                                        'Driving Licence',
                                        'Home Office Letter',
                                        'Immigration Status Document',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'GBR',
                                    reported_properties => {},
                                }}
                        },
                        needs_verification => ["document"],
                        needs_verification => [],
                    },
                    cashier_validation => ignore(),
                },
                'Dont allow for further resubmission if MX client is fully authenticated.'
            );

            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            subtest "Age verified client, check for expiry of documents" => sub {
                # For age verified clients
                # we will only check for iom and malta. (expiry of documents)

                $test_client_mx->set_authentication('ID_DOCUMENT', {status => 'pending'});
                $test_client_mx->save;
                $mocked_status->mock('age_verification',  sub { return 1 });
                $mocked_client->mock('documents_expired', sub { return 1 });
                $mocked_client->mock(
                    'documents_uploaded',
                    sub {
                        return {
                            proof_of_identity => {
                                documents => {
                                    $test_client_mx->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('10d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 2,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                        };
                    });

                my $documents              = $test_client_mx->documents_uploaded();
                my $is_poi_already_expired = $documents->{proof_of_identity}->{is_expired};
                ok !$test_client_mx->fully_authenticated, 'Not fully authenticated';
                ok $test_client_mx->status->age_verification, 'Age verified';
                ok $is_poi_already_expired, 'POI expired';
                $result = $c->tcall($method, {token => $token_mx});
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "GBP" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status                        => superbagof(qw(allow_document_upload document_expired)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '1',
                        authentication                => {
                            document => {
                                status => "none",
                            },
                            identity => {
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => [
                                            'Asylum Registration Card',
                                            'Certificate of Naturalisation',
                                            'Driving Licence',
                                            'Home Office Letter',
                                            'Immigration Status Document',
                                            'Passport',
                                            'Residence Permit',
                                            'Visa'
                                        ],
                                        country_code        => 'GBR',
                                        reported_properties => {},
                                    }}
                            },
                            needs_verification => superbagof(qw(identity)),
                        },
                        cashier_validation => ignore(),
                    },
                    "authentication object is correct"
                );

                $mocked_client->unmock_all();
                $mocked_status->unmock_all();
            };
        };
    };

    subtest "account authentication" => sub {
        subtest "fully authenicated" => sub {
            my $mocked_client = Test::MockModule->new(ref($test_client));
            # mark as fully authenticated
            $test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
            $test_client->save;

            my $mocked_status = Test::MockModule->new(ref($test_client->status));
            $mocked_status->mock('age_verification', sub { return 1 });

            my $result = $c->tcall($method, {token => $token});
            subtest "with valid documents" => sub {
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "EUR" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status => superbagof(
                            qw(allow_document_upload age_verification authenticated financial_information_not_complete financial_assessment_not_complete)
                        ),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
                            document => {
                                status => "verified",
                            },
                            identity => {
                                status   => "verified",
                                services => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                    }}
                            },
                            needs_verification => [],
                        },
                        cashier_validation => ignore(),
                    },
                    'correct authenication object for authenticated client with valid documents'
                );
            };

            subtest "with expired documents" => sub {
                $mocked_client->mock(
                    'documents_uploaded',
                    sub {
                        return {
                            proof_of_address => {
                                documents => {
                                    $test_client->loginid
                                        . '_bankstatement' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'bankstatement',
                                        format      => 'pdf',
                                        id          => 1,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                            proof_of_identity => {
                                documents => {
                                    $test_client->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 2,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                        };
                    });

                my $result = $c->tcall($method, {token => $token});
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "EUR" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status => superbagof(qw(age_verification authenticated financial_information_not_complete financial_assessment_not_complete)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
                            document => {
                                status => "verified",
                            },
                            identity => {
                                status      => "expired",
                                expiry_date => $result->{authentication}{identity}{expiry_date},
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                    }}
                            },
                            needs_verification => ["identity"],
                        },
                        cashier_validation => ignore(),
                    },
                    'correct authentication object for authenticated client with expired documents'
                );

            };

            subtest "check for expired documents if landing company required that" => sub {
                $mocked_client->mock(
                    'documents_uploaded',
                    sub {
                        return {
                            proof_of_address => {
                                documents => {
                                    $test_client->loginid
                                        . '_bankstatement' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'bankstatement',
                                        format      => 'pdf',
                                        id          => 1,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                            proof_of_identity => {
                                documents => {
                                    $test_client->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 2,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                        };
                    });

                my $method_response = $c->tcall($method, {token => $token});
                my $expected_result = {
                    document => {
                        status => "verified",
                    },
                    identity => {
                        status      => "expired",
                        expiry_date => re('\d+'),
                        services    => {
                            onfido => {
                                submissions_left     => $onfido_limit,
                                last_rejected        => [],
                                documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                is_country_supported => 1,
                                country_code         => 'IDN',
                                reported_properties  => {},
                            },
                        },
                    },
                    needs_verification => ['identity'],
                };

                my $result = $method_response->{authentication};
                cmp_deeply($result, $expected_result, "correct authenication object for authenticated client with expired documents");
            };
            $mocked_status->unmock_all;
            $mocked_client->unmock_all;
        };

        subtest "age verified" => sub {
            my $mocked_client = Test::MockModule->new(ref($test_client));
            my $mocked_status = Test::MockModule->new(ref($test_client->status));
            $mocked_status->mock('age_verification', sub { return 1 });

            $test_client->get_authentication('ID_DOCUMENT')->delete;
            $test_client->save;

            subtest "with valid documents" => sub {
                my $result = $c->tcall($method, {token => $token});
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "EUR" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status              => superbagof(qw(age_verification financial_information_not_complete financial_assessment_not_complete)),
                        risk_classification => 'low',
                        prompt_client_to_authenticate => 1,
                        authentication                => {
                            document => {
                                status => "none",
                            },
                            identity => {
                                status   => "verified",
                                services => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                    }}
                            },
                            needs_verification => ["document"],
                        },
                        cashier_validation => ignore(),
                    },
                    'correct authenication object for age verified client only'
                );
            };

            subtest "with expired documents" => sub {
                $mocked_client->mock(
                    'documents_uploaded',
                    sub {
                        return {
                            proof_of_identity => {
                                documents => {
                                    $test_client->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 1,
                                        status      => 'verified'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                        };
                    });

                my $result = $c->tcall($method, {token => $token});
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "EUR" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status              => superbagof(qw(age_verification financial_information_not_complete financial_assessment_not_complete)),
                        risk_classification => 'low',
                        prompt_client_to_authenticate => 1,
                        authentication                => {
                            identity => {
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                    }}
                            },
                            document => {
                                status => "none",
                            },
                            needs_verification => ["document", "identity"]
                        },
                        cashier_validation => ignore(),
                    },
                    'correct authenication object for age verified client with expired documents'
                );
            };

            $mocked_status->unmock_all;
            $mocked_client->unmock_all;
        };

        subtest 'unauthorize' => sub {
            $test_client->status->clear_age_verification;
            $test_client->get_authentication('ID_DOCUMENT')->delete;
            $test_client->save;

            my $result = $c->tcall($method, {token => $token});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "EUR" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(financial_information_not_complete financial_assessment_not_complete)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => 1,
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => ["document", "identity"],
                    },
                    cashier_validation => ignore(),
                },
                'correct authenication object for unauthenticated client'
            );
        };

        subtest 'shared payment method' => sub {
            $test_client_cr->status->clear_age_verification;
            $test_client_cr->status->set('shared_payment_method');
            $test_client_cr->status->set('cashier_locked');

            my $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "USD" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status                        => superbagof(qw(cashier_locked shared_payment_method)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => 0,
                    authentication                => {
                        document => {
                            status => "none",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                }}
                        },
                        needs_verification => ["identity"],
                    },
                },
                'correct authenication object for shared_payment_method client'
            );
        };
    };
};

my $test_client_onfido = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    residence   => 'aq',
});
$test_client_onfido->email('sample_onfido@binary.com');
$test_client_onfido->set_default_account('USD');
$test_client_onfido->save;

my $user_onfido = BOM::User->create(
    email    => 'sample_onfido@binary.com',
    password => $hash_pwd
);

$user_onfido->add_client($test_client_onfido);

my $test_client_onfido2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    place_of_birth => 'id',
    residence      => 'aq',
});
$test_client_onfido2->email('sample_onfido2@binary.com');
$test_client_onfido2->set_default_account('USD');
$test_client_onfido2->save;

my $user_onfido2 = BOM::User->create(
    email    => 'sample_onfido2@binary.com',
    password => $hash_pwd
);

$user_onfido2->add_client($test_client_onfido2);

my $token_cr_onfido  = $m->create_token($test_client_onfido->loginid,  'test token');
my $token_cr_onfido2 = $m->create_token($test_client_onfido2->loginid, 'test token');

subtest "Test onfido is_country_supported" => sub {
    my $result = $c->tcall($method, {token => $token_cr_onfido});
    cmp_deeply(
        $result,
        {
            currency_config => {
                "USD" => {
                    is_deposit_suspended    => 0,
                    is_withdrawal_suspended => 0,
                }
            },
            status                        => noneof(qw(authenticated)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '0',
            authentication                => {
                document => {
                    status => "none",
                },
                identity => {
                    status   => "none",
                    services => {
                        onfido => {
                            submissions_left     => $onfido_limit,
                            last_rejected        => [],
                            is_country_supported => 0,
                            documents_supported  => [],
                            country_code         => 'ATA',
                            reported_properties  => {},
                        }}
                },
                needs_verification => [],
            }
        },
        'Onfido-unsupported country correct response'
    );

    $result = $c->tcall($method, {token => $token_cr_onfido2});
    cmp_deeply(
        $result,
        {
            currency_config => {
                "USD" => {
                    is_deposit_suspended    => 0,
                    is_withdrawal_suspended => 0,
                }
            },
            status                        => noneof(qw(authenticated)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '0',
            authentication                => {
                document => {
                    status => "none",
                },
                identity => {
                    status   => "none",
                    services => {
                        onfido => {
                            submissions_left     => $onfido_limit,
                            last_rejected        => [],
                            is_country_supported => 1,
                            documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                            country_code         => 'IDN',
                            reported_properties  => {},
                        }}
                },
                needs_verification => [],
            }
        },
        'is_country_supported uses POB as priority when checking'
    );
};

my $test_client_experian = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
});
$test_client_experian->email('sample_experian@binary.com');
$test_client_experian->set_default_account('GBP');
$test_client_experian->save;
my $user_experian = BOM::User->create(
    email    => 'user_experian@binary.com',
    password => $hash_pwd
);

$user_experian->add_client($test_client_experian);
my $token_client_experian = $m->create_token($test_client_experian->loginid, 'test token');

$user_experian->update_trading_password('Abcd12345');
subtest 'Experian validated account' => sub {
    $test_client_experian->status->upsert('age_verification',  'test', 'Experian results are sufficient to mark client as age verified.');
    $test_client_experian->status->upsert('proveid_requested', 'test', 'ProveID request has been made for this account.');
    $test_client_experian->set_authentication('ID_ONLINE', {status => 'pass'});
    my $mocked_client = Test::MockModule->new(ref($test_client));

    subtest 'Low Risk' => sub {
        $test_client_experian->aml_risk_classification('low');
        $test_client_experian->save;

        my $result = $c->tcall($method, {token => $token_client_experian});
        cmp_deeply(
            $result,
            {
                currency_config => {
                    "GBP" => {
                        is_deposit_suspended    => 0,
                        is_withdrawal_suspended => 0,
                    }
                },
                status => superbagof(
                    qw(age_verification authenticated allow_document_upload financial_information_not_complete trading_experience_not_complete)),
                risk_classification           => 'low',
                prompt_client_to_authenticate => 0,
                authentication                => {
                    document => {
                        status => "verified",
                    },
                    identity => {
                        status   => "verified",
                        services => {
                            onfido => {
                                submissions_left     => $onfido_limit,
                                last_rejected        => [],
                                is_country_supported => 1,
                                documents_supported  => [
                                    'Asylum Registration Card',
                                    'Certificate of Naturalisation',
                                    'Driving Licence',
                                    'Home Office Letter',
                                    'Immigration Status Document',
                                    'Passport',
                                    'Residence Permit',
                                    'Visa'
                                ],
                                country_code        => 'GBR',
                                reported_properties => {},
                            }}
                    },
                    needs_verification => []
                },
                cashier_validation => ignore(),
            },
            'Experian validated low risk account does not need POI validation'
        );
    };

    subtest 'High Risk' => sub {
        $test_client_experian->aml_risk_classification('high');
        $test_client_experian->save;

        my $result = $c->tcall($method, {token => $token_client_experian});
        cmp_deeply(
            $result,
            {
                currency_config => {
                    "GBP" => {
                        is_deposit_suspended    => 0,
                        is_withdrawal_suspended => 0,
                    }
                },
                status => superbagof(
                    qw(age_verification authenticated allow_document_upload financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)
                ),
                risk_classification           => 'high',
                prompt_client_to_authenticate => 0,
                authentication                => {
                    document => {
                        status => "none",
                    },
                    identity => {
                        status   => "none",
                        services => {
                            onfido => {
                                submissions_left     => $onfido_limit,
                                last_rejected        => [],
                                is_country_supported => 1,
                                documents_supported  => [
                                    'Asylum Registration Card',
                                    'Certificate of Naturalisation',
                                    'Driving Licence',
                                    'Home Office Letter',
                                    'Immigration Status Document',
                                    'Passport',
                                    'Residence Permit',
                                    'Visa'
                                ],
                                country_code        => 'GBR',
                                reported_properties => {},
                            }}
                    },
                    needs_verification => supersetof('identity', 'document'),
                },
                cashier_validation => ignore(),
            },
            'Experian validated high risk account needs POI and POA validation'
        );

        subtest 'Client uploaded POA' => sub {
            $mocked_client->mock(
                'documents_uploaded',
                sub {
                    return {
                        proof_of_address => {
                            is_pending => 1,
                        }};
                });

            my $result = $c->tcall($method, {token => $token_client_experian});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "GBP" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status => superbagof(
                        qw(age_verification authenticated allow_document_upload financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)
                    ),
                    risk_classification           => 'high',
                    prompt_client_to_authenticate => 0,
                    authentication                => {
                        document => {
                            status => "pending",
                        },
                        identity => {
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Certificate of Naturalisation',
                                        'Driving Licence',
                                        'Home Office Letter',
                                        'Immigration Status Document',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'GBR',
                                    reported_properties => {},
                                }}
                        },
                        needs_verification => ['identity']
                    },
                    cashier_validation => ignore(),
                },
                'Experian validated high risk account has pending status after Docs upload'
            );

            subtest 'POA uploaded is approved in the BO' => sub {
                # The BO drops all the authentications before setting it up again
                $_->delete for @{$test_client_experian->client_authentication_method};
                $test_client_experian->set_authentication('ID_DOCUMENT', {status => 'pass'});

                $mocked_client->mock(
                    'documents_uploaded',
                    sub {
                        return {
                            proof_of_address => {
                                is_pending => 0,
                            }};
                    });

                my $result = $c->tcall($method, {token => $token_client_experian});
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "GBP" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status => superbagof(
                            qw(age_verification authenticated allow_document_upload financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)
                        ),
                        risk_classification           => 'high',
                        prompt_client_to_authenticate => 0,
                        authentication                => {
                            document => {
                                status => "verified",
                            },
                            identity => {
                                status   => "verified",
                                services => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => [
                                            'Asylum Registration Card',
                                            'Certificate of Naturalisation',
                                            'Driving Licence',
                                            'Home Office Letter',
                                            'Immigration Status Document',
                                            'Passport',
                                            'Residence Permit',
                                            'Visa'
                                        ],
                                        country_code        => 'GBR',
                                        reported_properties => {},
                                    }}
                            },
                            needs_verification => [],
                        },
                        cashier_validation => ignore(),
                    },
                    'Former Experian validated high risk account has verified POA and POI when fully authenticated'
                );
            };
        };

        subtest 'Client uploaded Onfido docs' => sub {
            my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
            my $onfido_document_status;

            $mocked_onfido->mock(
                'get_latest_check',
                sub {
                    return {
                        report_document_status     => $onfido_document_status,
                        report_document_sub_result => undef,
                    };
                });

            $onfido_document_status = 'in_progress';

            my $result = $c->tcall($method, {token => $token_client_experian});
            cmp_deeply(
                $result,
                {
                    currency_config => {
                        "GBP" => {
                            is_deposit_suspended    => 0,
                            is_withdrawal_suspended => 0,
                        }
                    },
                    status => superbagof(
                        qw(age_verification authenticated allow_document_upload financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)
                    ),
                    risk_classification           => 'high',
                    prompt_client_to_authenticate => 0,
                    authentication                => {
                        document => {
                            status => "verified",
                        },
                        identity => {
                            status   => "pending",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Certificate of Naturalisation',
                                        'Driving Licence',
                                        'Home Office Letter',
                                        'Immigration Status Document',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'GBR',
                                    reported_properties => {},
                                }}
                        },
                        needs_verification => [],
                    },
                    cashier_validation => ignore(),
                },
                'Experian validated high risk account has pending status after Onfido upload'
            );

            $mocked_onfido->unmock_all;

            subtest 'Onfido docs are accepted' => sub {
                $test_client_experian->status->upsert('age_verification', 'system', 'Onfido - age verified');

                my $result = $c->tcall($method, {token => $token_client_experian});
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "GBP" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status => superbagof(
                            qw(age_verification authenticated allow_document_upload financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)
                        ),
                        risk_classification           => 'high',
                        prompt_client_to_authenticate => 0,
                        authentication                => {
                            document => {
                                status => "verified",
                            },
                            identity => {
                                status   => "verified",
                                services => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => [
                                            'Asylum Registration Card',
                                            'Certificate of Naturalisation',
                                            'Driving Licence',
                                            'Home Office Letter',
                                            'Immigration Status Document',
                                            'Passport',
                                            'Residence Permit',
                                            'Visa'
                                        ],
                                        country_code        => 'GBR',
                                        reported_properties => {},
                                    }}
                            },
                            needs_verification => []
                        },
                        cashier_validation => ignore(),
                    },
                    'Former Experian validated high risk does not need POI as the validator is Onfido now'
                );
            };

            subtest 'Onfido docs expired' => sub {
                my $mocked_client = Test::MockModule->new(ref($test_client_experian));
                $mocked_client->mock(
                    'documents_uploaded',
                    sub {
                        return {
                            proof_of_identity => {
                                documents => {
                                    $test_client_experian->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 1,
                                        status      => 'uploaded'
                                        },
                                },
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired  => 1,
                            },
                        };
                    });

                my $result = $c->tcall($method, {token => $token_client_experian});
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "GBP" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        status => superbagof(
                            qw(age_verification authenticated allow_document_upload financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete document_expired)
                        ),
                        risk_classification           => 'high',
                        prompt_client_to_authenticate => 0,
                        authentication                => {
                            document => {
                                status => "verified",
                            },
                            identity => {
                                status      => "expired",
                                expiry_date => re('.*'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => [
                                            'Asylum Registration Card',
                                            'Certificate of Naturalisation',
                                            'Driving Licence',
                                            'Home Office Letter',
                                            'Immigration Status Document',
                                            'Passport',
                                            'Residence Permit',
                                            'Visa'
                                        ],
                                        country_code        => 'GBR',
                                        reported_properties => {},
                                    }}
                            },
                            needs_verification => ['identity'],
                        },
                        cashier_validation => ignore(),
                    },
                    'Former Experian validated high risk account has expired status after Onfido upload and docs expired'
                );

                $mocked_client->unmock_all;
            };
        };
    };
};

subtest 'Rejected reasons' => sub {
    my $test_client_rejected = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'br',
    });
    $test_client_rejected->email('testing.rejected+reasons@binary.com');
    $test_client_rejected->set_default_account('USD');
    $test_client_rejected->save;

    my $user_rejected = BOM::User->create(
        email    => 'testing.rejected+reasons@binary.com',
        password => 'hey you'
    );

    $user_rejected->add_client($test_client_rejected);

    my $token_rejected = $m->create_token($test_client_rejected->loginid, 'test token');

    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    my $poi_status  = 'rejected';
    my $poi_name_mismatch;
    my $reasons = [];

    $onfido_mock->mock(
        'get_consider_reasons',
        sub {
            return $reasons;
        });

    my $client_mock = Test::MockModule->new('BOM::User::Client');
    $client_mock->mock(
        'get_poi_status',
        sub {
            return $poi_status;
        });

    my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
    $status_mock->mock(
        'poi_name_mismatch',
        sub {
            return $poi_name_mismatch;
        });

    my %catalog = %BOM::RPC::v3::Accounts::RejectedOnfidoReasons;
    my $tests   = [map { +{reasons => [$_], poi_status => 'rejected', expected => [$catalog{$_}], test => "Testing $_",} } keys %catalog];

    # Adding more cases

    push $tests->@*,
        {
        reasons    => [qw/too much garbage/],
        expected   => [],
        test       => 'Not declared reasons are filtered out',
        poi_status => 'suspected',
        };

    push $tests->@*,
        {
        reasons    => ['data_comparison.first_name', 'data_comparison.last_name'],
        expected   => ["The name on your document doesn't match your profile."],
        test       => 'Duplicated message is reported once',
        poi_status => 'suspected',
        };

    push $tests->@*,
        {
        reasons  => ['data_comparison.first_name', 'age_validation.minimum_accepted_age', 'selfie', 'garbage'],
        expected => [
            "The name on your document doesn't match your profile.",
            "Your age in the document you provided appears to be below 18 years. We're only allowed to offer our services to clients above 18 years old, so we'll need to close your account. If you have a balance in your account, contact us via live chat and we'll help to withdraw your funds before your account is closed.",
            "Your selfie isn't clear. Please take a clearer photo and try again. Ensure that there's enough light where you are and that your entire face is in the frame."
        ],
        test       => 'Multiple messages reported',
        poi_status => 'suspected',
        };

    push $tests->@*,
        {
        reasons    => ['data_comparison.first_name', 'age_validation.minimum_accepted_age', 'selfie', 'garbage'],
        expected   => [],
        test       => 'Empty rejected messages for verified account',
        poi_status => 'verified',
        };

    push $tests->@*,
        {
        reasons           => [],
        expected          => ["The name on your document doesn't match your profile.",],
        test              => 'From our rules (poi_name_mismatch)',
        poi_status        => 'suspected',
        poi_name_mismatch => 1,
        };

    push $tests->@*,
        {
        reasons           => [],
        expected          => ["The name on your document doesn't match your profile.",],
        test              => 'From our rules (poi_name_mismatch)',
        poi_status        => 'verified',
        poi_name_mismatch => 1,
        };

    push $tests->@*,
        {
        reasons           => [],
        expected          => [],
        test              => 'From our rules (poi_name_mismatch => undef)',
        poi_status        => 'verified',
        poi_name_mismatch => undef,
        };

    for my $test ($tests->@*) {
        $reasons           = $test->{reasons};
        $poi_status        = $test->{poi_status};
        $poi_name_mismatch = $test->{poi_name_mismatch};

        my $result        = $c->tcall($method, {token => $token_rejected});
        my $last_rejected = $result->{authentication}->{identity}->{services}->{onfido}->{last_rejected};
        cmp_deeply($last_rejected, $test->{expected}, $test->{test});
    }

    $onfido_mock->unmock_all;
    $client_mock->unmock_all;
    $status_mock->unmock_all;
};

subtest 'Reported properties' => sub {
    my $test_client_rejected = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'br',
    });
    $test_client_rejected->email('testing.reported+properties@binary.com');
    $test_client_rejected->set_default_account('USD');
    $test_client_rejected->save;

    my $user_rejected = BOM::User->create(
        email    => 'testing.reported+properties@binary.com',
        password => 'hey you'
    );

    $user_rejected->add_client($test_client_rejected);

    my $token_rejected = $m->create_token($test_client_rejected->loginid, 'test token');

    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    $onfido_mock->mock(
        'get_latest_onfido_check',
        sub {
            return {
                id => 'DOC',
            };
        });

    my $properties;
    $onfido_mock->mock(
        'get_all_onfido_reports',
        sub {
            return {
                DOC => {
                    result     => 'consider',
                    api_name   => 'document',
                    properties => encode_json_utf8($properties // {}),
                }};
        });

    my $tests = [{
            properties => undef,
            expected   => {},
        },
        {
            properties => {},
            expected   => {},
        },
        {
            properties => {first_name => 'mad'},
            expected   => {first_name => 'mad'},
        },
        {
            properties => {
                first_name => 'mad',
                last_name  => 'dog',
            },
            expected => {
                first_name => 'mad',
                last_name  => 'dog',
            },
        },
        {
            properties => {
                first_name => 'mad',
                last_name  => 'dog',
                age        => 90,
            },
            expected => {
                first_name => 'mad',
                last_name  => 'dog',
            },
        },
    ];

    for my $test ($tests->@*) {
        $properties = $test->{properties};

        my $result              = $c->tcall($method, {token => $token_rejected});
        my $reported_properties = $result->{authentication}->{identity}->{services}->{onfido}->{reported_properties};
        cmp_deeply($reported_properties, $test->{expected}, 'Expected reported properties seen');
    }

    $onfido_mock->unmock_all;
};

subtest 'Social identity provider' => sub {

    my $email = 'social' . rand(999) . '@binary.com';

    BOM::Platform::Account::Virtual::create_account({
            details => {
                'client_password'   => '418508.727020996',
                'source'            => '7',
                'email'             => $email,
                'residence'         => 'id',
                'has_social_signup' => 1,
                'brand_name'        => 'deriv'
            },
            utm_data => {
                'utm_content'      => undef,
                'utm_gl_client_id' => undef,
                'utm_campaign_id'  => undef,
                'utm_ad_id'        => undef,
                'utm_term'         => undef,
                'utm_msclk_id'     => undef,
                'utm_adrollclk_id' => undef,
                'utm_fbcl_id'      => undef,
                'utm_adgroup_id'   => undef
            }});

    my $residence = 'id';

    my $user         = BOM::User->new(email => $email);
    my $user_connect = BOM::Database::Model::UserConnect->new;
    $user_connect->insert_connect(
        $user->{id},
        {
            user => {
                identity => {
                    provider              => 'google',
                    provider_identity_uid => 123
                }}});

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client_cr->account('USD');
    $user->add_client($client_cr);

    my $token_cr = $m->create_token($client_cr->loginid, 'test token');

    my $result = $c->tcall($method, {token => $token_cr});
    cmp_deeply(
        $result,
        {
            social_identity_provider => 'google',
            status          => bag(qw(social_signup financial_information_not_complete trading_experience_not_complete trading_password_required)),
            currency_config => {
                'USD' => {
                    is_deposit_suspended    => 0,
                    is_withdrawal_suspended => 0
                }
            },
            prompt_client_to_authenticate => 0,
            risk_classification           => 'low',
            authentication                => {
                identity => {
                    services => {
                        onfido => {
                            submissions_left     => 3,
                            is_country_supported => 1,
                            last_rejected        => [],
                            documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport'],
                            country_code         => 'IDN',
                            reported_properties  => {},
                        }
                    },
                    status => 'none'
                },
                needs_verification => [],
                document           => {'status' => 'none'}
            },
        },
        'has social_identity_provider as google'
    );
};

subtest 'Empty country code scenario' => sub {
    my $user = BOM::User->create(
        email    => 'emptycountry@cc.com',
        password => 'Abcd4455',
    );
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $user->add_client($client);
    $client->place_of_birth('');
    $client->residence('');
    $client->save;

    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall($method, {token => $token});
    ok !exists($result->{authentication}->{identity}->{services}->{onfido}->{country_code}), 'Country code not reported';

    $client->place_of_birth('br');
    $client->residence('br');
    $client->save;

    $result = $c->tcall($method, {token => $token});
    is $result->{authentication}->{identity}->{services}->{onfido}->{country_code}, 'BRA', 'Expected country code found';
};

done_testing();
