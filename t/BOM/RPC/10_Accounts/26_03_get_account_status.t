use strict;
use warnings;

use Encode;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use Encode          qw(encode);
use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::BOM::RPC::QueueClient;

use Date::Utility;

use BOM::RPC::v3::Accounts;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Utility;
use BOM::User;
use BOM::Platform::Token;

my $c = Test::BOM::RPC::QueueClient->new();
my $m = BOM::Platform::Token::API->new;

my $fa_data = {
    "education_level"                      => "Secondary",
    "binary_options_trading_frequency"     => "0-5 transactions in the past 12 months",
    "source_of_wealth"                     => "Company Ownership",
    "forex_trading_experience"             => "0-1 year",
    "account_turnover"                     => 'Less than $25,000',
    "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",
    "employment_status"                    => "Self-Employed",
    "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
    "other_instruments_trading_frequency"  => "0-5 transactions in the past 12 months",
    "income_source"                        => "Self-Employed",
    "other_instruments_trading_experience" => "0-1 year",
    "net_income"                           => '$25,000 - $50,000',
    "cfd_trading_experience"               => "0-1 year",
    "occupation"                           => "Managers",
    "binary_options_trading_experience"    => "0-1 year",
    "estimated_worth"                      => '$100,000 - $250,000',
    "employment_industry"                  => "Health"
};

subtest 'check legacy cfd_score' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $user = BOM::User->create(
        email    => 'test+legacy_cfd_score@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client->status->set('financial_risk_approval', 'system', 'Accepted approval');
    $client->status->set('crs_tin_information',     'test',   'test');

    $client->aml_risk_classification('low');
    $client->set_default_account('EUR');
    $client->financial_assessment({
        data => encode_json_utf8($fa_data),
    });
    $client->save();

    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall('get_account_status', {token => $token});

    $client->aml_risk_classification('standard');
    $client->save();

    $result = $c->tcall('get_account_status', {token => $token});
    cmp_deeply(
        $result,
        {
            authentication => {
                attempts => {
                    count   => 0,
                    history => [],
                    latest  => undef
                },
                document => {
                    status                 => "verified",
                    authenticated_with_idv => {
                        dsl             => 0,
                        malta           => 0,
                        labuan          => 0,
                        virtual         => 0,
                        bvi             => 0,
                        samoa           => 0,
                        svg             => 0,
                        'samoa-virtual' => 0,
                        maltainvest     => 0,
                        iom             => 0,
                        vanuatu         => 0,
                    },
                },
                identity => {
                    services => {
                        idv => {
                            last_rejected       => [],
                            reported_properties => {},
                            status              => "none",
                            submissions_left    => 2,
                        },
                        manual => {status => "verified"},
                        onfido => {
                            country_code         => "IDN",
                            documents_supported  => ["Driving Licence", "National Identity Card", "Passport", "Residence Permit",],
                            is_country_supported => 1,
                            last_rejected        => [],
                            reported_properties  => {},
                            status               => "none",
                            submissions_left     => 1,
                        },
                    },
                    status => "verified",
                },
                income             => {status => "none"},
                needs_verification => [],
                ownership          => {
                    requests => [],
                    status   => "none"
                },
            },
            cashier_validation => ["FinancialAssessmentRequired"],
            currency_config    => {
                EUR => {
                    is_deposit_suspended    => 0,
                    is_withdrawal_suspended => 0
                },
            },
            p2p_poa_required              => 0,
            p2p_status                    => "none",
            prompt_client_to_authenticate => 0,
            risk_classification           => "standard",
            status                        => [
                "age_verification",         "allow_document_upload",             "authenticated",           "crs_tin_information",
                "dxtrade_password_not_set", "financial_assessment_not_complete", "financial_risk_approval", "idv_disallowed",
                "mt5_password_not_set",     "trading_experience_not_complete",   "withdrawal_locked",
            ],
        },
        'financial_assessment_not_complete, chashier deposit locked'
    );

    $fa_data->{cfd_trading_experience} = '1-2 years';
    $fa_data->{cfd_trading_frequency}  = '40 transactions or more in the past 12 months';
    $client->financial_assessment({
        data => encode_json_utf8($fa_data),
    });
    $client->save();
    $result = $c->tcall('get_account_status', {token => $token});
    cmp_deeply(
        $result,
        {
            authentication => {
                attempts => {
                    count   => 0,
                    history => [],
                    latest  => undef
                },
                document => {
                    status                 => "verified",
                    authenticated_with_idv => {
                        dsl             => 0,
                        malta           => 0,
                        labuan          => 0,
                        virtual         => 0,
                        bvi             => 0,
                        samoa           => 0,
                        svg             => 0,
                        'samoa-virtual' => 0,
                        maltainvest     => 0,
                        iom             => 0,
                        vanuatu         => 0,
                    },
                },
                identity => {
                    services => {
                        idv => {
                            last_rejected       => [],
                            reported_properties => {},
                            status              => "none",
                            submissions_left    => 2,
                        },
                        manual => {status => "verified"},
                        onfido => {
                            country_code         => "IDN",
                            documents_supported  => ["Driving Licence", "National Identity Card", "Passport", "Residence Permit",],
                            is_country_supported => 1,
                            last_rejected        => [],
                            reported_properties  => {},
                            status               => "none",
                            submissions_left     => 1,
                        },
                    },
                    status => "verified",
                },
                income             => {status => "none"},
                needs_verification => [],
                ownership          => {
                    requests => [],
                    status   => "none"
                },
            },
            currency_config => {
                EUR => {
                    is_deposit_suspended    => 0,
                    is_withdrawal_suspended => 0
                },
            },
            p2p_poa_required              => 0,
            p2p_status                    => "none",
            prompt_client_to_authenticate => 0,
            risk_classification           => "standard",
            status                        => [
                "age_verification",         "allow_document_upload",   "authenticated",  "crs_tin_information",
                "dxtrade_password_not_set", "financial_risk_approval", "idv_disallowed", "mt5_password_not_set",
            ],
        },
        'financial_assessment is complete, cashier is not locked, cfd score was used'
    );
};

subtest 'Fully Auth with IDV' => sub {
    my $client_mock = Test::MockModule->new('BOM::User::Client');

    my $is_idv_validated = 1;
    my $idv_status       = 'verified';

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

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'test+idvauth@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);
    $client->set_authentication_and_status('IDV_PHOTO', 'Sadwichito');
    ok $client->fully_authenticated, 'Fully authenticated';

    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall('get_account_status', {token => $token});
    cmp_deeply $result,
        +{
        status => [
            'allow_document_upload',              'authenticated',
            'cashier_locked',                     'dxtrade_password_not_set',
            'financial_information_not_complete', 'mt5_additional_kyc_required',
            'mt5_password_not_set',               'poa_authenticated_with_idv',
            'trading_experience_not_complete'
        ],
        p2p_poa_required => 0,
        p2p_status       => 'none',
        authentication   => {
            identity => {
                status   => 'verified',
                services => {
                    onfido => {
                        is_country_supported => 1,
                        reported_properties  => {},
                        last_rejected        => [],
                        status               => 'none',
                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                        country_code         => 'IDN',
                        submissions_left     => 1
                    },
                    idv => {
                        status              => 'verified',
                        last_rejected       => [],
                        reported_properties => {},
                        submissions_left    => 2
                    },
                    manual => {status => 'none'}}
            },
            ownership => {
                requests => [],
                status   => 'none'
            },
            attempts => {
                'history' => [],
                'count'   => 0,
                'latest'  => undef
            },
            needs_verification => [],
            income             => {'status' => 'none'},
            document           => {
                status                 => 'verified',
                authenticated_with_idv => {
                    dsl             => 0,
                    malta           => 0,
                    labuan          => 0,
                    virtual         => 0,
                    bvi             => 1,
                    samoa           => 0,
                    svg             => 1,
                    'samoa-virtual' => 0,
                    maltainvest     => 0,
                    iom             => 0,
                    vanuatu         => 0,
                },
            }
        },
        currency_config => {
            USD => {
                'is_deposit_suspended'    => 0,
                'is_withdrawal_suspended' => 0
            }
        },
        cashier_validation            => ['ASK_CURRENCY'],
        prompt_client_to_authenticate => 0,
        risk_classification           => 'low'
        },
        'expected response for IDV fully authenticated';

    ## client becomes high risk
    $client->aml_risk_classification('high');
    $client->save;

    $result = $c->tcall('get_account_status', {token => $token});
    cmp_deeply $result,
        +{
        status => [
            'allow_document_upload',              'cashier_locked',
            'dxtrade_password_not_set',           'financial_assessment_not_complete',
            'financial_information_not_complete', 'idv_disallowed',
            'idv_revoked',                        'mt5_additional_kyc_required',
            'mt5_password_not_set',               'trading_experience_not_complete'
        ],
        p2p_poa_required => 0,
        p2p_status       => 'none',
        authentication   => {
            identity => {
                status   => 'none',
                services => {
                    onfido => {
                        is_country_supported => 1,
                        reported_properties  => {},
                        last_rejected        => [],
                        status               => 'none',
                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                        country_code         => 'IDN',
                        submissions_left     => 1
                    },
                    idv => {
                        status              => 'verified',
                        last_rejected       => [],
                        reported_properties => {},
                        submissions_left    => 2
                    },
                    manual => {status => 'none'}}
            },
            ownership => {
                requests => [],
                status   => 'none'
            },
            attempts => {
                'history' => [],
                'count'   => 0,
                'latest'  => undef
            },
            needs_verification => [qw/document identity/],
            income             => {'status' => 'none'},
            document           => {
                status                 => 'none',
                authenticated_with_idv => {
                    dsl             => 0,
                    malta           => 0,
                    labuan          => 0,
                    virtual         => 0,
                    bvi             => 0,
                    samoa           => 0,
                    svg             => 0,
                    'samoa-virtual' => 0,
                    maltainvest     => 0,
                    iom             => 0,
                    vanuatu         => 0,
                },
            }
        },
        currency_config => {
            USD => {
                'is_deposit_suspended'    => 0,
                'is_withdrawal_suspended' => 0
            }
        },
        cashier_validation            => ['ASK_AUTHENTICATE', 'ASK_CURRENCY', 'FinancialAssessmentRequired'],
        prompt_client_to_authenticate => 1,
        risk_classification           => 'high'
        },
        'expected response for IDV authenticated under high risk scenario';

    $client_mock->unmock_all;
};

subtest 'poi/idv status rejected for diel acc check latest_poi_by' => sub {
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $mock_status = 'rejected';

    $client_mock->mock(
        'get_idv_status',
        sub {
            return $mock_status;
        });

    $client_mock->mock(
        'get_poi_status',
        sub {
            return $mock_status;
        });

    my $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $user = BOM::User->create(
        email    => 'test+idv+diel@deriv.com',
        password => 'Abcd1234'
    );
    $user->add_client($cr_client);
    $user->add_client($mf_client);

    $cr_client->status->set('age_verification', 'system', 'idv');

    my $token_cr = $m->create_token($cr_client->loginid, 'test token');
    my $token_mf = $m->create_token($mf_client->loginid, 'test token');
    my $result   = $c->tcall('get_account_status', {token => $token_cr});

    cmp_deeply $result->{authentication}->{identity},
        +{
        status   => 'rejected',
        services => {
            onfido => {
                is_country_supported => 1,
                reported_properties  => {},
                last_rejected        => [],
                status               => 'none',
                documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                country_code         => 'IDN',
                submissions_left     => 1
            },
            idv => {
                status              => 'rejected',
                last_rejected       => [],
                reported_properties => {},
                submissions_left    => 2
            },
            manual => {status => 'none'}}
        },
        'expected response for IDV verified for CR acc';

    $result = $c->tcall('get_account_status', {token => $token_mf});

    cmp_deeply $result->{authentication}->{identity},
        +{
        status   => 'rejected',
        services => {
            onfido => {
                is_country_supported => 1,
                reported_properties  => {},
                last_rejected        => [],
                status               => 'none',
                documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                country_code         => 'IDN',
                submissions_left     => 1
            },
            idv => {
                status              => 'rejected',
                last_rejected       => [],
                reported_properties => {},
                submissions_left    => 2
            },
            manual => {status => 'none'}}
        },
        'expected response for IDV verified for MF acc';
};

subtest 'expired docs account' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $user = BOM::User->create(
        email    => 'test+expired+docs@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);

    $client->status->set('financial_risk_approval', 'system', 'Accepted approval');
    $client->status->set('crs_tin_information',     'test',   'test');
    $client->status->set('age_verification',        'test',   'test');
    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client->aml_risk_classification('high');
    $client->set_default_account('EUR');
    $client->financial_assessment({
        data => encode_json_utf8($fa_data),
    });
    $client->save();

    my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    my $documents;

    $documents_mock->mock(
        'uploaded',
        sub {
            my ($self) = @_;
            $self->_clear_uploaded;
            return $documents // {};
        });

    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall('get_account_status', {token => $token});

    ok !$result->{cashier_validation}, 'cashier validation passes';

    $documents = {
        proof_of_identity => {
            is_expired    => 1,
            to_be_expired => -30,
            documents     => {
                document1 => {
                    type => 'passport',
                }}}};

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{cashier_validation}, ['documents_expired'], 'cashier validation has errors';

    $documents = {
        proof_of_identity => {
            is_expired => 1,
            documents  => {
                document1 => {
                    type => 'passport',
                }
            },
        },
        onfido => {
            documents => {
                document1 => {
                    type => 'passport',
                }
            },
            is_expired => 0,
        }};

    $result = $c->tcall('get_account_status', {token => $token});

    ok !$result->{cashier_validation}, 'cashier validation passes';

    $documents = {
        proof_of_identity => {
            is_expired => 1,
            documents  => {
                document1 => {
                    type => 'passport',
                }
            },
        },
        # no exp date onfido doc!
        onfido => {
            documents => {
                document1 => {
                    type => 'passport',
                }
            },
        }};

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{cashier_validation}, ['documents_expired'], 'cashier validation has errors';

    $documents = {
        proof_of_identity => {
            is_expired => 1,
            documents  => {
                document1 => {
                    type => 'passport',
                }
            },
        },
        onfido => {
            documents => {
                document1 => {
                    type => 'passport',
                }
            },
            lifetime_valid => 1,
        }};

    $result = $c->tcall('get_account_status', {token => $token});

    ok !$result->{cashier_validation}, 'cashier validation passes';

    $documents = {
        proof_of_identity => {
            is_expired => 1,
            documents  => {
                document1 => {
                    type => 'passport',
                }
            },
        },
        onfido => {
            documents => {
                document1 => {
                    type => 'passport',
                }
            },
            is_expired => 1,
        }};

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{cashier_validation}, ['documents_expired'], 'cashier validation has errors';

    $documents_mock->unmock_all;
};

subtest 'poi soon to be expired' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $user = BOM::User->create(
        email    => 'poi+soon+to+be+expired@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);

    $client->status->set('financial_risk_approval', 'system', 'Accepted approval');
    $client->status->set('crs_tin_information',     'test',   'test');
    $client->status->set('age_verification',        'test',   'test');
    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client->aml_risk_classification('high');
    $client->set_default_account('EUR');
    $client->financial_assessment({
        data => encode_json_utf8($fa_data),
    });

    $client->save();

    my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    my $documents;

    $documents_mock->mock(
        'uploaded',
        sub {
            my ($self) = @_;
            $self->_clear_uploaded;
            return $documents // {};
        });

    my $user_mock = Test::MockModule->new(ref($user));
    my $has_mt5_regulated_account;
    $user_mock->mock(
        'has_mt5_regulated_account',
        sub {
            return $has_mt5_regulated_account;
        });

    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall('get_account_status', {token => $token});

    cmp_bag $result->{status},
        [
        'age_verification',         'allow_document_upload',   'authenticated',  'crs_tin_information',
        'dxtrade_password_not_set', 'financial_risk_approval', 'idv_disallowed', 'mt5_password_not_set'
        ],
        'Expected statuses';

    $documents = {
        proof_of_identity => {
            is_expired    => 1,
            to_be_expired => -90,
            documents     => {
                test => {
                    test => 1,
                    type => 'passport'
                }}}};

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_bag $result->{status},
        [
        'age_verification',         'allow_document_upload',   'authenticated',  'crs_tin_information',
        'dxtrade_password_not_set', 'financial_risk_approval', 'idv_disallowed', 'mt5_password_not_set',
        'cashier_locked',           'document_expired',
        ],
        'Expected statuses while expired';

    $has_mt5_regulated_account = 1;
    $result                    = $c->tcall('get_account_status', {token => $token});

    cmp_bag $result->{status},
        [
        'age_verification',         'allow_document_upload',   'authenticated',  'crs_tin_information',
        'dxtrade_password_not_set', 'financial_risk_approval', 'idv_disallowed', 'mt5_password_not_set',
        'cashier_locked',           'document_expired',        'poi_expiring_soon'
        ],
        'Expected statuses while expired + having mt5 regulated';

    $documents = {};
    $result    = $c->tcall('get_account_status', {token => $token});
    $documents = {
        proof_of_identity => {
            is_expired    => 1,
            to_be_expired => -91,
            documents     => {test => {test => 1}}}};

    cmp_bag $result->{status},
        [
        'age_verification',         'allow_document_upload',   'authenticated',  'crs_tin_information',
        'dxtrade_password_not_set', 'financial_risk_approval', 'idv_disallowed', 'mt5_password_not_set'
        ],
        'Expected statuses, not within the boundary';

    $documents = {};
    $result    = $c->tcall('get_account_status', {token => $token});
    $documents = {
        proof_of_identity => {
            is_expired    => 1,
            to_be_expired => undef,
            documents     => {test => {test => 1}}}};

    cmp_bag $result->{status},
        [
        'age_verification',         'allow_document_upload',   'authenticated',  'crs_tin_information',
        'dxtrade_password_not_set', 'financial_risk_approval', 'idv_disallowed', 'mt5_password_not_set'
        ],
        'Expected statuses, undef to be expired';

    $documents_mock->unmock_all;
    $user_mock->unmock_all;
};

subtest 'poa soon to be outdated' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $user = BOM::User->create(
        email    => 'poi+soon+to+be+outdated@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);

    $client->status->set('financial_risk_approval', 'system', 'Accepted approval');
    $client->status->set('crs_tin_information',     'test',   'test');
    $client->status->set('age_verification',        'test',   'test');
    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client->aml_risk_classification('high');
    $client->set_default_account('EUR');
    $client->financial_assessment({
        data => encode_json_utf8($fa_data),
    });
    $client->save();

    my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    my $documents;

    $documents_mock->mock(
        'uploaded',
        sub {
            my ($self) = @_;
            $self->_clear_uploaded;
            return $documents // {};
        });

    my $user_mock = Test::MockModule->new(ref($user));
    my $has_mt5_regulated_account;
    $user_mock->mock(
        'has_mt5_regulated_account',
        sub {
            return $has_mt5_regulated_account;
        });

    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall('get_account_status', {token => $token});

    cmp_bag $result->{status},
        [
        'age_verification',         'allow_document_upload',   'authenticated',  'crs_tin_information',
        'dxtrade_password_not_set', 'financial_risk_approval', 'idv_disallowed', 'mt5_password_not_set'
        ],
        'Expected statuses';

    $documents = {
        proof_of_address => {
            is_outdated    => 1,
            to_be_outdated => -90,
            documents      => {test => {test => 1}}}};

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_bag $result->{status},
        [
        'age_verification',         'allow_document_upload',   'authenticated',  'crs_tin_information',
        'dxtrade_password_not_set', 'financial_risk_approval', 'idv_disallowed', 'mt5_password_not_set',
        'document_expired'
        ],
        'Expected statuses while outdated';

    $has_mt5_regulated_account = 1;
    $result                    = $c->tcall('get_account_status', {token => $token});

    cmp_bag $result->{status},
        [
        'age_verification',         'allow_document_upload',   'authenticated',  'crs_tin_information',
        'dxtrade_password_not_set', 'financial_risk_approval', 'idv_disallowed', 'mt5_password_not_set',
        'poa_expiring_soon',        'document_expired'
        ],
        'Expected statuses while outdated + having mt5 regulated';

    $documents = {};
    $result    = $c->tcall('get_account_status', {token => $token});

    cmp_bag $result->{status},
        [
        'age_verification',         'allow_document_upload',   'authenticated',  'crs_tin_information',
        'dxtrade_password_not_set', 'financial_risk_approval', 'idv_disallowed', 'mt5_password_not_set'
        ],
        'Expected statuses, not within the boundary';

    $documents = {};
    $result    = $c->tcall('get_account_status', {token => $token});

    cmp_bag $result->{status},
        [
        'age_verification',         'allow_document_upload',   'authenticated',  'crs_tin_information',
        'dxtrade_password_not_set', 'financial_risk_approval', 'idv_disallowed', 'mt5_password_not_set'
        ],
        'Expected statuses, undef to be expired';

    $documents_mock->unmock_all;
    $user_mock->unmock_all;
};

subtest 'POA state machine' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'test+poa+state+machine@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);
    $client->set_default_account('EUR');
    $client->save();

    my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    my $documents;

    $documents_mock->mock(
        'uploaded',
        sub {
            my ($self) = @_;
            $self->_clear_uploaded;
            return $documents // {};
        });
    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall('get_account_status', {token => $token});

    is $result->{authentication}->{document}->{status}, 'none', 'Nothing uploaded';

    $documents = {
        proof_of_address => {
            documents => {
                $client->loginid
                    . '_bankstatement' => {
                    expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                    type        => 'bankstatement',
                    format      => 'pdf',
                    id          => 1,
                    status      => 'uploaded'
                    },
            },
            is_pending => 1,
        },
    };

    $result = $c->tcall('get_account_status', {token => $token});

    is $result->{authentication}->{document}->{status}, 'pending', 'Pending document';

    $documents = {
        proof_of_address => {
            documents => {
                $client->loginid
                    . '_bankstatement' => {
                    expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                    type        => 'bankstatement',
                    format      => 'pdf',
                    id          => 1,
                    status      => 'uploaded'
                    },
            },
            is_rejected => 1,
        },
    };

    $result = $c->tcall('get_account_status', {token => $token});

    is $result->{authentication}->{document}->{status}, 'rejected', 'Rejected document';

    $documents = {
        proof_of_address => {
            documents => {
                $client->loginid
                    . '_bankstatement' => {
                    expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                    type        => 'bankstatement',
                    format      => 'pdf',
                    id          => 1,
                    status      => 'uploaded'
                    },
            },
            is_verified => 1,
        },
    };

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $result = $c->tcall('get_account_status', {token => $token});

    is $result->{authentication}->{document}->{status}, 'verified', 'Verified document';

    $documents = {
        proof_of_address => {
            documents => {
                $client->loginid
                    . '_bankstatement' => {
                    expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                    type        => 'bankstatement',
                    format      => 'pdf',
                    id          => 1,
                    status      => 'uploaded'
                    },
            },
            is_rejected => 1,
        },
    };

    $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'});
    $result = $c->tcall('get_account_status', {token => $token});

    is $result->{authentication}->{document}->{status}, 'rejected', 'Rejected document';

    $documents = {
        proof_of_address => {
            documents => {
                $client->loginid
                    . '_bankstatement' => {
                    expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                    type        => 'bankstatement',
                    format      => 'pdf',
                    id          => 1,
                    status      => 'uploaded'
                    },
            },
            is_pending => 1,
        },
    };

    $client->set_authentication('ID_DOCUMENT', {status => 'under_review'});
    $result = $c->tcall('get_account_status', {token => $token});

    is $result->{authentication}->{document}->{status}, 'pending', 'Pending document';

    $documents = {
        proof_of_address => {
            documents => {
                $client->loginid
                    . '_bankstatement' => {
                    expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                    type        => 'bankstatement',
                    format      => 'pdf',
                    id          => 1,
                    status      => 'uploaded'
                    },
            },
            is_outdated => 1,
        },
    };

    $client->set_authentication('ID_DOCUMENT', {status => 'under_review'});
    $result = $c->tcall('get_account_status', {token => $token});

    is $result->{authentication}->{document}->{status}, 'expired', 'Expired document';

    $documents = {
        proof_of_address => {
            documents => {
                $client->loginid
                    . '_bankstatement' => {
                    expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                    type        => 'bankstatement',
                    format      => 'pdf',
                    id          => 1,
                    status      => 'uploaded'
                    },
            },
            is_outdated => 1,
        },
    };

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $result = $c->tcall('get_account_status', {token => $token});

    is $result->{authentication}->{document}->{status}, 'expired', 'Expired document';

    $documents = {
        proof_of_address => {
            documents => {
                $client->loginid
                    . '_bankstatement' => {
                    expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                    type        => 'bankstatement',
                    format      => 'pdf',
                    id          => 1,
                    status      => 'uploaded'
                    },
            },
            is_verified => 1,
        },
    };

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $result = $c->tcall('get_account_status', {token => $token});

    is $result->{authentication}->{document}->{status}, 'verified', 'Verified document';
};

subtest 'Onfido duplicated document rejected reason' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'test+dup_doc@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);
    $client->set_default_account('EUR');
    $client->save();

    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{identity}->{services}->{onfido}->{last_rejected}, [], 'No rejected reasons';

    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    $onfido_mock->mock(
        'get_consider_reasons',
        sub {
            return ['duplicated_document'];
        });

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{identity}->{services}->{onfido}->{last_rejected}, [], 'No rejected reasons (poi status must be rejected)';

    my $cli_mock = Test::MockModule->new('BOM::User::Client');
    my $poi_status;
    $cli_mock->mock(
        'get_poi_status',
        sub {
            return $poi_status;
        });
    $cli_mock->mock(
        'latest_poi_by',
        sub {
            return ('onfido');
        });

    $poi_status = 'rejected';
    $result     = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{identity}->{services}->{onfido}->{last_rejected}, ["DuplicatedDocument"], 'Dup document reason';

    $poi_status = 'suspected';
    $result     = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{identity}->{services}->{onfido}->{last_rejected}, ["DuplicatedDocument"], 'Dup document reason';

    $poi_status = 'verified';
    $result     = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{identity}->{services}->{onfido}->{last_rejected}, [], 'No rejected reasons';

    $onfido_mock->unmock_all;
    $cli_mock->unmock_all;
};

subtest "suspended onfido" => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'test+onfido+suspended@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);
    $client->set_default_account('USD');
    $client->save();

    my $token = $m->create_token($client->loginid, 'test token');

    my $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result,
        +{
        status => [
            'allow_document_upload',              'dxtrade_password_not_set',
            'financial_information_not_complete', 'mt5_additional_kyc_required',
            'mt5_password_not_set',               'trading_experience_not_complete'
        ],
        p2p_status     => 'none',
        authentication => {
            identity => {
                status   => 'none',
                services => {
                    onfido => {
                        is_country_supported => 1,
                        reported_properties  => {},
                        last_rejected        => [],
                        status               => 'none',
                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                        country_code         => 'IDN',
                        submissions_left     => 1
                    },
                    idv => {
                        status              => 'none',
                        last_rejected       => [],
                        reported_properties => {},
                        submissions_left    => 2
                    },
                    manual => {status => 'none'}}
            },
            ownership => {
                requests => [],
                status   => 'none'
            },
            attempts => {
                'history' => [],
                'count'   => 0,
                'latest'  => undef
            },
            needs_verification => [],
            income             => {'status' => 'none'},
            document           => {
                'status'               => 'none',
                authenticated_with_idv => {
                    dsl             => 0,
                    malta           => 0,
                    labuan          => 0,
                    virtual         => 0,
                    bvi             => 0,
                    samoa           => 0,
                    svg             => 0,
                    'samoa-virtual' => 0,
                    maltainvest     => 0,
                    iom             => 0,
                    vanuatu         => 0,
                }}
        },
        currency_config => {
            USD => {
                'is_deposit_suspended'    => 0,
                'is_withdrawal_suspended' => 0
            }
        },
        prompt_client_to_authenticate => 0,
        risk_classification           => 'low',
        p2p_poa_required              => 0
        },
        'expected response for onfido active';

    BOM::Config::Runtime->instance->app_config->system->suspend->onfido(1);

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result,
        +{
        status => [
            'allow_document_upload',              'dxtrade_password_not_set',
            'financial_information_not_complete', 'mt5_additional_kyc_required',
            'mt5_password_not_set',               'onfido_suspended',
            'trading_experience_not_complete'
        ],
        p2p_status     => 'none',
        authentication => {
            identity => {
                status   => 'none',
                services => {
                    onfido => {
                        is_country_supported => 0,
                        reported_properties  => {},
                        last_rejected        => [],
                        status               => 'none',
                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                        country_code         => 'IDN',
                        submissions_left     => 1
                    },
                    idv => {
                        status              => 'none',
                        last_rejected       => [],
                        reported_properties => {},
                        submissions_left    => 2
                    },
                    manual => {status => 'none'}}
            },
            ownership => {
                requests => [],
                status   => 'none'
            },
            attempts => {
                'history' => [],
                'count'   => 0,
                'latest'  => undef
            },
            needs_verification => [],
            income             => {'status' => 'none'},
            document           => {
                'status'               => 'none',
                authenticated_with_idv => {
                    dsl             => 0,
                    malta           => 0,
                    labuan          => 0,
                    virtual         => 0,
                    bvi             => 0,
                    samoa           => 0,
                    svg             => 0,
                    'samoa-virtual' => 0,
                    maltainvest     => 0,
                    iom             => 0,
                    vanuatu         => 0,
                }}
        },
        currency_config => {
            USD => {
                'is_deposit_suspended'    => 0,
                'is_withdrawal_suspended' => 0
            }
        },
        prompt_client_to_authenticate => 0,
        risk_classification           => 'low',
        p2p_poa_required              => 0
        },
        'expected response for onfido suspended';

    BOM::Config::Runtime->instance->app_config->system->suspend->onfido(0);
};

done_testing();
