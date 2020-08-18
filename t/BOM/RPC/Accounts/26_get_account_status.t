use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::Client;
use Encode;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use Encode qw(encode);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;
use BOM::Platform::Token::API;
use BOM::User::Password;
use BOM::User;
use BOM::Test::Helper::Token;

use BOM::Config::Redis;

BOM::Test::Helper::Token::cleanup_redis_tokens();

my $email       = 'abc@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
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

my $test_client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
    citizen     => ''
});
$test_client_mx->email($email);

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
my $token          = $m->create_token($test_client->loginid, 'test token');
my $token_cr       = $m->create_token($test_client_cr->loginid, 'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_mx       = $m->create_token($test_client_mx->loginid, 'test token');
my $token_mlt      = $m->create_token($test_client_mlt->loginid, 'test token');

my $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
my $c = Test::BOM::RPC::Client->new(ua => $t->app->ua);

my $method = 'get_account_status';
subtest 'get account status' => sub {
    subtest "account generic" => sub {

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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => ["document", "identity"],
                    }
                },
                'prompt for non authenticated MF client'
            );

            $test_client->set_authentication('ID_DOCUMENT')->status('pass');
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
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0
                        },
                        identity => {
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => [],
                    }
                },
                'authenticated, no deposits so it will not prompt for authentication'
            );

            my $mocked_client = Test::MockModule->new(ref($test_client));
            $mocked_client->mock('documents_expired', sub { return 1 });
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
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => [],
                    }
                },
                'correct account status returned for document expired, please note that this test for status key, authentication expiry structure is tested later'
            );

            $mocked_client->mock('documents_expired', sub { return 0 });
            $mocked_client->mock(
                'is_any_document_expiring_by_date',
                sub {
                    my ($self, $date) = @_;
                    return 0 unless $date;
                    my $date_obj = Date::Utility->new($date);
                    return 1
                        if $date_obj->is_after(Date::Utility->today)
                        and $date_obj->is_before(Date::Utility->today->plus_time_interval('1mo')->plus_time_interval('1d'));
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
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => [],
                    }
                },
                'correct account status returned for document expiring in next month'
            );

            $mocked_client->unmock('documents_expired');
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
                    status                        => [qw(financial_information_not_complete trading_experience_not_complete)],
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => [],
                    }
                },
                'allow_document_upload is automatically added along with withdrawal_locked'
            );
            $test_client_cr->status->clear_withdrawal_locked;

            $test_client_cr->set_authentication('ID_DOCUMENT')->status('needs_action');
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => ["document"],
                    }
                },
                'authentication page should be shown for proof of address if needs action is set for age verified clients'
            );
            $mocked_status->unmock_all();

            $test_client_cr->set_authentication('ID_DOCUMENT')->status('under_review');
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
                    status                        => superbagof(qw(document_under_review)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => [],
                    }
                },
                'prompt_client_to_authenticate should not be set if under review is set regardless of balance'
            );

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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => ["document", "identity"],
                    }
                },
                'ask for documents for unauthenticated client marked as high risk'
            );

            # Revert under review state
            $test_client_cr->aml_risk_classification('low');
            $test_client_cr->save;

            $test_client_cr->status->set('age_verification',      'system', 'age verified');
            $test_client_cr->status->set('allow_document_upload', 'system', 1);
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => [],
                    }
                },
                'allow_document_upload flag is set if client is not authenticated and status exists on client'
            );

            my $mocked_client = Test::MockModule->new(ref($test_client_cr));
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
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => [],
                    }
                },
                'test if all manual status has been removed'
            );

        };

        subtest 'futher resubmission allowed' => sub {
            # Redis key for poa resubmission flag
            use constant POA_ALLOW_RESUBMISSION_KEY_PREFIX => 'POA::ALLOW_RESUBMISSION::ID::';
            my $redis = BOM::Config::Redis::redis_replicated_write();
            $redis->set(POA_ALLOW_RESUBMISSION_KEY_PREFIX . $test_client_cr->binary_user_id, 1);    # Activate the flag

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
                    status                        => [qw(financial_information_not_complete trading_experience_not_complete)],
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 1,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => [],
                    }
                },
                'poa further_resubmissions_allowed is set to 1 correctly'
            );

            $redis->del(POA_ALLOW_RESUBMISSION_KEY_PREFIX . $test_client_cr->binary_user_id);
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => ["document", "identity"],
                    }
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => [],
                    }
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => ["document", "identity"],
                    }
                },
                'ask for documents for malta client if first deposit has been done and not authorized'
            );
            $mocked_client->unmock_all;
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => ["document", "identity"],
                    }
                },
                'ask for documents for client marked as high risk'
            );

            $test_client_mx->aml_risk_classification('low');
            $test_client_mx->save;

            my $mocked_client = Test::MockModule->new(ref($test_client_mx));
            $mocked_client->mock('is_first_deposit_pending', sub { return 0 });

            my $mocked_status = Test::MockModule->new(ref($test_client_mx->status));
            $mocked_status->mock('age_verification', sub { return 1 });
            $mocked_status->mock('unwelcome',        sub { return 1 });

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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                            services                        => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => ["document"],
                    }
                },
                'ask for proof of address documents for iom client if age verified client is marked as unwelcome'
            );
            $mocked_client->unmock_all;
            $mocked_status->unmock_all;
        };
    };

    subtest "account authentication" => sub {
        subtest "fully authenicated" => sub {
            my $mocked_client = Test::MockModule->new(ref($test_client));
            # mark as fully authenticated
            $test_client->set_authentication('ID_DOCUMENT')->status('pass');
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
                                status                          => "verified",
                                "further_resubmissions_allowed" => 0,
                            },
                            identity => {
                                status                          => "verified",
                                "further_resubmissions_allowed" => 0,
                                services                        => {
                                    onfido => {
                                        is_country_supported => 0,
                                        documents_supported  => []}}
                            },
                            needs_verification => [],
                        }
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
                                        status      => 'uploaded'
                                        },
                                },
                                minimum_expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired          => 1,
                            },
                            proof_of_identity => {
                                documents => {
                                    $test_client->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 2,
                                        status      => 'uploaded'
                                        },
                                },
                                minimum_expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired          => 1,
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
                                status                          => "expired",
                                "further_resubmissions_allowed" => 0,
                                expiry_date                     => $result->{authentication}{document}{expiry_date}
                            },
                            identity => {
                                status                        => "expired",
                                expiry_date                   => $result->{authentication}{identity}{expiry_date},
                                further_resubmissions_allowed => 0,
                                services                      => {
                                    onfido => {
                                        is_country_supported => 0,
                                        documents_supported  => []}}
                            },
                            needs_verification => ["document", "identity"],
                        }
                    },
                    'correct authenication object for authenticated client with expired documents'
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
                                        status      => 'uploaded'
                                        },
                                },
                                minimum_expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired          => 1,
                            },
                            proof_of_identity => {
                                documents => {
                                    $test_client->loginid
                                        . '_passport' => {
                                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                        type        => 'passport',
                                        format      => 'pdf',
                                        id          => 2,
                                        status      => 'uploaded'
                                        },
                                },
                                minimum_expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                is_expired          => 1,
                            },
                        };
                    });

                for my $is_required (1, 0) {
                    $mocked_client->mock(
                        'is_document_expiry_check_required_mt5',
                        sub {
                            return $is_required;
                        });

                    my $method_response = $c->tcall($method, {token => $token});

                    my $expected_result = {
                        document => {
                            status                          => "verified",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                        => "verified",
                            further_resubmissions_allowed => 0,
                            services                      => {
                                onfido => {
                                    documents_supported  => [],
                                    is_country_supported => 0
                                },
                            },
                        },
                        needs_verification => [],
                    };

                    if ($is_required) {
                        $expected_result->{identity}->{status}      = "expired";
                        $expected_result->{identity}->{expiry_date} = $method_response->{authentication}{identity}{expiry_date};
                        $expected_result->{document}->{status}      = "expired";
                        $expected_result->{document}->{expiry_date} = $method_response->{authentication}{document}{expiry_date};
                        push(@{$expected_result->{needs_verification}}, 'document');
                        push(@{$expected_result->{needs_verification}}, 'identity');
                    }

                    my $result = $method_response->{authentication};
                    cmp_deeply($result, $expected_result, "correct authenication object for authenticated client with expired documents");
                }
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
                                status                          => "none",
                                "further_resubmissions_allowed" => 0,
                            },
                            identity => {
                                status                        => "verified",
                                further_resubmissions_allowed => 0,
                                services                      => {
                                    onfido => {
                                        is_country_supported => 0,
                                        documents_supported  => []}}
                            },
                            needs_verification => ["document"],
                        }
                    },
                    'correct authenication object for age verified client only'
                );
            };

            subtest "with expired documents" => sub {
                subtest "with expired proof of address only" => sub {
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
                                            status      => 'uploaded'
                                            },
                                    },
                                    minimum_expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                    is_expired          => 1,
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
                            status => superbagof(qw(age_verification financial_information_not_complete financial_assessment_not_complete)),
                            risk_classification           => 'low',
                            prompt_client_to_authenticate => 1,
                            authentication                => {
                                document => {
                                    status                          => "expired",
                                    expiry_date                     => $result->{authentication}{document}{expiry_date},
                                    "further_resubmissions_allowed" => 0,
                                },
                                identity => {
                                    status                        => "verified",
                                    further_resubmissions_allowed => 0,
                                    services                      => {
                                        onfido => {
                                            is_country_supported => 0,
                                            documents_supported  => []}}
                                },
                                needs_verification => ["document"]}
                        },
                        'correct authenication object for age verified client with expired documents'
                    );
                };

                subtest "with only poi expired" => sub {
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
                                            status      => 'uploaded'
                                            },
                                    },
                                    minimum_expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                    is_expired          => 1,
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
                            status => superbagof(qw(age_verification financial_information_not_complete financial_assessment_not_complete)),
                            risk_classification           => 'low',
                            prompt_client_to_authenticate => 1,
                            authentication                => {
                                identity => {
                                    status                        => "expired",
                                    expiry_date                   => $result->{authentication}{identity}{expiry_date},
                                    further_resubmissions_allowed => 0,
                                    services                      => {
                                        onfido => {
                                            is_country_supported => 0,
                                            documents_supported  => []}}
                                },
                                document => {
                                    status                          => "none",
                                    "further_resubmissions_allowed" => 0,
                                },
                                needs_verification => ["document", "identity"]}
                        },
                        'correct authenication object for age verified client with expired proof of identity documents'
                    );
                };
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
                            status                          => "none",
                            "further_resubmissions_allowed" => 0,
                        },
                        identity => {
                            status                        => "none",
                            further_resubmissions_allowed => 0,
                            services                      => {
                                onfido => {
                                    is_country_supported => 0,
                                    documents_supported  => []}}
                        },
                        needs_verification => ["document", "identity"]}
                },
                'correct authenication object for unauthenticated client'
            );
        };
    };

};

done_testing();
