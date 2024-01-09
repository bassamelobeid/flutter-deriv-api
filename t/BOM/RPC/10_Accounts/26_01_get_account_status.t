use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use List::Util;
use Encode;
use JSON::MaybeUTF8                            qw(encode_json_utf8);
use Encode                                     qw(encode);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;
use BOM::Test::Helper::P2P;
use BOM::Platform::Token::API;
use BOM::Platform::Utility;
use BOM::User::Password;
use BOM::User;
use BOM::User::Onfido;
use BOM::Test::Helper::Token;
use Test::BOM::RPC::QueueClient;
use Syntax::Keyword::Try;
use BOM::Config::Redis;

BOM::Test::Helper::Token::cleanup_redis_tokens();
BOM::Test::Helper::P2P::bypass_sendbird();

my $idv_limit    = 3;
my $onfido_limit = BOM::User::Onfido::limit_per_user;
my $email        = 'abc@binary.com';
my $password     = 'jskjd8292922';
my $hash_pwd     = BOM::User::Password::hashpw($password);
my $test_client  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client->email($email);
$test_client->set_default_account('EUR');
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

my $test_client_p2p = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    citizen     => 'id',
});

$test_client_p2p->email('sample@binary.com');
$test_client_p2p->set_default_account('USD');
$test_client_p2p->save;

my $user_cr = BOM::User->create(
    email    => 'sample@binary.com',
    password => $hash_pwd
);

$user_cr->add_client($test_client_cr_vr);
$user_cr->add_client($test_client_cr);
$user_cr->add_client($test_client_cr_2);
$user_cr->add_client($test_client_p2p);

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

my $test_client_crw = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code  => 'CRW',
    account_type => 'doughflow',
    email        => 'wallet@test.com',
});

my $test_client_std = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code  => 'CR',
    account_type => 'standard',
    email        => $test_client_crw->email,
});

my $wallet_user = BOM::User->create(
    email    => $test_client_crw->email,
    password => 'x',
);

$wallet_user->add_client($test_client_crw);
$wallet_user->add_client($test_client_std);
$test_client_crw->account('USD');
$test_client_std->account('USD');
$wallet_user->link_wallet_to_trading_account({wallet_id => $test_client_crw->loginid, client_id => $test_client_std->loginid});

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_client->loginid,          'test token');
my $token_vr       = $m->create_token($test_client_cr_vr->loginid,    'test token');
my $token_cr       = $m->create_token($test_client_cr->loginid,       'test token');
my $token_p2p      = $m->create_token($test_client_p2p->loginid,      'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_mx       = $m->create_token($test_client_mx->loginid,       'test token');
my $token_mlt      = $m->create_token($test_client_mlt->loginid,      'test token');
my $token_crw      = $m->create_token($test_client_crw->loginid,      'test token');
my $token_std      = $m->create_token($test_client_std->loginid,      'test token');

my $c = Test::BOM::RPC::QueueClient->new();

my $documents_expired;
my $documents_uploaded;

my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
$documents_mock->mock(
    'expired',
    sub {
        my ($self) = @_;

        return $documents_expired if defined $documents_expired;
        return $documents_mock->original('expired')->(@_);
    });

$documents_mock->mock(
    'uploaded',
    sub {
        my ($self) = @_;

        $self->_clear_uploaded;

        return $documents_uploaded if defined $documents_uploaded;
        return $documents_mock->original('uploaded')->(@_);
    });

my $method = 'get_account_status';
subtest 'get account status' => sub {
    subtest "account generic" => sub {

        subtest 'cashier statuses' => sub {
            my $mocked_cashier_validation = Test::MockModule->new("BOM::Platform::Client::CashierValidation");

            my $result = $c->tcall('get_account_status', {token => $token_vr});
            cmp_deeply(
                $result->{status},
                [
                    'cashier_locked',                     'dxtrade_password_not_set',
                    'financial_information_not_complete', 'idv_disallowed',
                    'mt5_password_not_set',               'trading_experience_not_complete',

                ],
                "cashier is locked for virtual accounts"
            );

            # base validatioon: empty action type
            my $validation = {'' => {error => 1}};
            $mocked_cashier_validation->redefine(
                validate => sub {
                    my %args = @_;

                    return $validation->{$args{action}};
                });
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                [
                    'allow_document_upload',    'cashier_locked',
                    'dxtrade_password_not_set', 'financial_information_not_complete', 'mt5_additional_kyc_required',
                    'mt5_password_not_set',     'trading_experience_not_complete',

                ],
                "cashier is locked correctly."
            );

            $validation->{''} = {};
            $result = $c->tcall('get_account_status', {token => $token_cr});

            cmp_deeply(
                $result->{status},
                [
                    'allow_document_upload',              'dxtrade_password_not_set',
                    'financial_information_not_complete', 'mt5_additional_kyc_required',
                    'mt5_password_not_set',               'trading_experience_not_complete',
                ],
                "cashier is not locked for correctly"
            );

            $validation->{withdrawal} = {error => 1};
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                [
                    'allow_document_upload',              'dxtrade_password_not_set',
                    'financial_information_not_complete', 'mt5_additional_kyc_required',
                    'mt5_password_not_set',               'trading_experience_not_complete',
                    'withdrawal_locked',
                ],
                "withdrawal is locked correctly"
            );

            $validation->{withdrawal} = {};
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                [
                    'allow_document_upload',              'dxtrade_password_not_set',
                    'financial_information_not_complete', 'mt5_additional_kyc_required',
                    'mt5_password_not_set',               'trading_experience_not_complete'
                ],
                "withdrawal is not locked correctly"
            );

            $validation->{deposit} = {error => 1};
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                [
                    'allow_document_upload',       'deposit_locked',
                    'dxtrade_password_not_set',    'financial_information_not_complete',
                    'mt5_additional_kyc_required', 'mt5_password_not_set',
                    'trading_experience_not_complete',
                ],
                "deposit is not locked correctly"
            );

            $validation->{deposit} = {};
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                [
                    'allow_document_upload',              'dxtrade_password_not_set',
                    'financial_information_not_complete', 'mt5_additional_kyc_required',
                    'mt5_password_not_set',               'trading_experience_not_complete',
                ],
                "deposit is not locked correctly"
            );

            $validation = {
                ''         => {},
                deposit    => {error => 1},
                withdrawal => {error => 1}};
            $result = $c->tcall('get_account_status', {token => $token_cr});
            cmp_deeply(
                $result->{status},
                [
                    'allow_document_upload',       'cashier_locked',
                    'dxtrade_password_not_set',    'financial_information_not_complete',
                    'mt5_additional_kyc_required', 'mt5_password_not_set',
                    'trading_experience_not_complete',
                ],
                "cashier_locked when both deposit and withdrawal are locked"
            );

            $mocked_cashier_validation->unmock_all();

            cmp_deeply(
                $c->tcall('get_account_status', {token => $token_vr})->{cashier_validation},
                supersetof('CashierNotAllowed'),
                'VRTC gets CashierNotAllowed in cashier_validation'
            );

            cmp_deeply(
                $c->tcall('get_account_status', {token => $token_crw})->{cashier_validation},
                none('CashierNotAllowed'),
                'CRW does not get CashierNotAllowed in cashier_validation'
            );

            cmp_deeply(
                $c->tcall('get_account_status', {token => $token_std})->{cashier_validation},
                supersetof('CashierNotAllowed'),
                'CR standard gets CashierNotAllowed in cashier_validation'
            );
        };

        subtest 'p2p status' => sub {
            my $result = $c->tcall('get_account_status', {token => $token_cr});
            is $result->{p2p_status}, "none", "client is not a P2P advertiser";

            my $advertiser = $test_client_p2p->p2p_advertiser_create(name => "p2p test user");

            $result = $c->tcall('get_account_status', {token => $token_p2p});
            is $result->{p2p_status}, "active", "client is a P2P advertiser";

            BOM::Test::Helper::P2P::set_advertiser_blocked_until($test_client_p2p, 1);
            BOM::Test::Helper::P2P::set_advertiser_is_enabled($test_client_p2p, 0);
            $result = $c->tcall('get_account_status', {token => $token_p2p});
            is $result->{p2p_status}, "perm_ban", "P2P advertiser is fully blocked, permanent block takes precedence over temporary block";

            BOM::Test::Helper::P2P::set_advertiser_is_enabled($test_client_p2p, 1);
            $result = $c->tcall('get_account_status', {token => $token_p2p});
            is $result->{p2p_status}, "temp_ban", "P2P advertiser is temporarily blocked";

            BOM::Test::Helper::P2P::set_advertiser_blocked_until($test_client_p2p, 0);

        };

        subtest 'Check additional_kyc_required is triggered status for CR clients' => sub {

            my $password = 'Abcd33!@';
            my $hash_pwd = BOM::User::Password::hashpw($password);
            my $email    = 'cr1_email' . rand(999) . '@binary.com';
            my $user     = BOM::User->create(
                email          => $email,
                password       => $hash_pwd,
                email_verified => 1,
            );
            my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code   => 'CR',
                    email         => $email,
                    residence     => 'id',
                    secret_answer => BOM::User::Utility::encrypt_secret_answer('mysecretanswer')});
            my $auth_token = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
            my $result     = $c->tcall('get_account_status', {token => $auth_token});

            ## Check if mt5_additional_kyc_required is in list of status
            my $is_triggered = scalar grep { $_ eq 'mt5_additional_kyc_required' } $result->{status}->@*;

            is $is_triggered, 1, "mt5_additional_kyc_required is triggered";
            # set field values to trigger mt5_additional_kyc_required
            $client_cr1->tax_residence('id');
            $client_cr1->tax_identification_number('1112222');
            $client_cr1->place_of_birth('id');
            $client_cr1->account_opening_reason('Speculative');
            $client_cr1->save;

            $result = $c->tcall('get_account_status', {token => $auth_token});
            ## Check if mt5_additional_kyc_required is in list of status
            $is_triggered = scalar grep { $_ eq 'mt5_additional_kyc_required' } $result->{status}->@*;
            is $is_triggered, 0, "mt5_additional_kyc_required is not triggered";
        };
        subtest 'Check mt5_additional_kyc_required is not triggered for malatinvest clients' => sub {

            my $password = 'Abcd33!@';
            my $hash_pwd = BOM::User::Password::hashpw($password);
            my $email    = 'cr1_email' . rand(999) . '@binary.com';
            my $user     = BOM::User->create(
                email          => $email,
                password       => $hash_pwd,
                email_verified => 1,
            );
            my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code   => 'MF',
                    email         => $email,
                    residence     => 'id',
                    secret_answer => BOM::User::Utility::encrypt_secret_answer('mysecretanswer')});
            my $auth_token = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
            my $result     = $c->tcall('get_account_status', {token => $auth_token});

            ## Check if mt5_additional_kyc_required is in list of status
            my $is_triggered = scalar grep { $_ eq 'mt5_additional_kyc_required' } $result->{status}->@*;

            is $is_triggered, 0, "mt5_additional_kyc_required is not triggered for MF";

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
            my $data = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_set_fa()->{trading_experience_regulated};
            # function to repeatedly test financial assessment
            sub test_financial_assessment {
                my ($data, $is_financial_assessment_present, $is_financial_information_present, $msg) = @_;
                $test_client->financial_assessment({
                    data => encode_json_utf8($data),
                });
                $test_client->save();
                my $result = $c->tcall($method, {token => $token});
                my $financial_assessment_not_complete =
                    ((grep { $_ eq 'financial_assessment_not_complete' } @{$result->{status}}) == $is_financial_assessment_present);
                my $financial_information_not_complete =
                    ((grep { $_ eq 'financial_information_not_complete' } @{$result->{status}}) == $is_financial_information_present);
                ok($financial_assessment_not_complete,  $msg);
                ok($financial_information_not_complete, $msg);
            }

            # 'financial_assessment_not_complete' should not present when everything is complete
            test_financial_assessment($data, 0, 1, 'financial_assessment_not_complete should be present when low risk and no fa');

            $test_client->aml_risk_classification('high');
            $test_client->save();

            $data = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1);
            # 'financial_assessment_not_complete' should not present when everything is complete
            test_financial_assessment($data, 0, 0, 'financial_assessment_not_complete should not be present with when high risk');

            # When some questions are not answered
            # FI is no longer required for all risk for deposits
            delete $data->{account_turnover};
            test_financial_assessment($data, 0, 1, 'financial_assessment_not_complete should present when questions are not answered');

            # When some answers are empty
            $data->{account_turnover} = "";
            test_financial_assessment($data, 0, 1, 'financial_assessment_not_complete should be present when some answers are empty');

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
                    p2p_poa_required              => 0,
                    p2p_status                    => 'none',
                    status                        => noneof(qw(duplicate_account)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income             => {status => 'none'},
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    }
                },
                'duplicate_account is not in the status'
            );

            $test_client->status->clear_duplicate_account;

            # reset the risk classification for the following test
            $test_client->aml_risk_classification('low');
            $test_client->save();

            $result = $c->tcall($method, {token => $token});
            $test_client->status->set('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
            $test_client->status->set('crs_tin_information',     'SYSTEM', 'Client accepted financial risk disclosure');

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
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income             => {status => 'none'},
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    },
                    cashier_validation => ['ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION', 'FinancialAssessmentRequired'],
                    p2p_poa_required   => 0,
                    p2p_status         => "none",
                },
                'prompt for non authenticated MF client'
            );

            $test_client->aml_risk_classification('standard');
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
                    status                        => superbagof(qw(authenticated withdrawal_locked)),
                    risk_classification           => 'standard',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
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
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'verified',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income             => {status => 'none'},
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    },
                    cashier_validation => ['FinancialAssessmentRequired'],
                    p2p_poa_required   => 0,
                    p2p_status         => "none",
                },
                'authenticated, no deposits so it will not prompt for authentication'
            );

            my $mocked_client = Test::MockModule->new(ref($test_client));
            my @latest_poi_by;
            $mocked_client->mock('latest_poi_by',  sub { return @latest_poi_by });
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
                    status                        => superbagof(qw(document_expired withdrawal_locked)),
                    risk_classification           => 'standard',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
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
                            status   => "expired",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'verified',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income             => {status => 'none'},
                        needs_verification => ['identity'],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    },
                    cashier_validation => ['FinancialAssessmentRequired'],
                    p2p_poa_required   => 0,
                    p2p_status         => "none",
                },
                'correct account status returned for document expired, please note that this test for status key, authentication expiry structure is tested later'
            );

            $mocked_client->mock('get_poi_status', sub { return 'verified' });
            $documents_uploaded = {
                proof_of_identity => {
                    documents => {
                        $test_client->loginid
                            . '_passport' => {
                            expiry_date => Date::Utility->new->minus_time_interval('10d')->epoch,
                            type        => 'passport',
                            format      => 'pdf',
                            id          => 2,
                            status      => 'uploaded'
                            },
                    },
                    expiry_date => Date::Utility->new->plus_time_interval('1d')->epoch,
                    is_expired  => 0,
                    is_pending  => 1,
                },
            };

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
                    status                        => superbagof(qw(withdrawal_locked)),
                    risk_classification           => 'standard',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
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
                            status      => "verified",
                            expiry_date => $documents_uploaded->{proof_of_identity}->{expiry_date},
                            services    => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'pending',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income             => {status => 'none'},
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    },
                    cashier_validation => ['FinancialAssessmentRequired'],
                    p2p_poa_required   => 0,
                    p2p_status         => "none",
                },
                'correct account status returned for document expiring in next month'
            );

            $documents_uploaded = undef;
            $mocked_client->unmock('get_poi_status');

            subtest "Age verified client, check for expiry of documents" => sub {
                # For age verified clients
                # we will only check for iom and malta. (expiry of documents)

                $test_client->set_authentication('ID_DOCUMENT', {status => 'pending'});
                $test_client->save;

                my $mocked_status = Test::MockModule->new(ref($test_client->status));
                $mocked_status->mock(
                    'age_verification',
                    sub {
                        return +{
                            staff_name => 'system',
                            reason     => 'test'
                        };
                    });
                $documents_uploaded = {
                    proof_of_identity => {
                        documents => {
                            $test_client->loginid
                                . '_passport' => {
                                expiry_date => Date::Utility->new->minus_time_interval('10d')->epoch,
                                type        => 'passport',
                                format      => 'pdf',
                                id          => 2,
                                status      => 'uploaded'
                                },
                        },
                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                        is_expired  => 1,
                    },
                };

                my $documents              = $test_client->documents->uploaded();
                my $is_poi_already_expired = $documents->{proof_of_identity}->{is_expired};
                @latest_poi_by = ('manual');
                ok !$test_client->fully_authenticated,     'Not fully authenticated';
                ok $test_client->status->age_verification, 'Age verified';
                ok $is_poi_already_expired,                'POI expired';
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
                        p2p_poa_required              => 0,
                        p2p_status                    => "none",
                        status                        => superbagof(qw(allow_document_upload document_expired)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '1',
                        authentication                => {
                            document => {
                                status                 => "none",
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
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => [
                                            'Asylum Registration Card',
                                            'Driving Licence',
                                            'Immigration Status Document',
                                            'National Health Insurance Card',
                                            'National Identity Card',
                                            'Passport',
                                            'Residence Permit',
                                            'Visa'
                                        ],
                                        country_code        => 'GBR',
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'expired',
                                    }}
                            },
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            income             => {status => 'none'},
                            needs_verification => superbagof(qw(identity)),
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
                        },
                        cashier_validation => ['ASK_CURRENCY', 'ASK_UK_FUNDS_PROTECTION', 'documents_expired'],
                        p2p_status         => "none",
                    },
                    "authentication object is correct"
                );

                $documents_uploaded = undef;
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
                    p2p_poa_required => 0,
                    p2p_status       => "none",
                    status           => [
                        qw(allow_document_upload dxtrade_password_not_set financial_information_not_complete mt5_additional_kyc_required mt5_password_not_set trading_experience_not_complete)
                    ],
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income             => {status => 'none'},
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
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
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income             => {status => 'none'},
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    },
                    cashier_validation => ['withdrawal_locked_status'],
                    p2p_poa_required   => 0,
                    p2p_status         => "none",
                },
                'allow_document_upload is automatically added along with withdrawal_locked'
            );

            $test_client_cr->status->clear_withdrawal_locked;

            my $mocked_client = Test::MockModule->new(ref($test_client_cr));
            $mocked_client->mock(locked_for_false_profile_info => sub { return 1 });
            cmp_deeply(
                $c->tcall($method, {token => $token_cr})->{status},
                superbagof(qw(allow_document_upload)),
                'allow_document_upload found due to locked account for false profile info'
            );
            $mocked_client->unmock('locked_for_false_profile_info');

            $test_client_cr->status->set('unwelcome', 'system', 'For test purposes');
            cmp_deeply(
                $c->tcall($method, {token => $token_cr})->{status},
                superbagof(qw(unwelcome)),
                'allow_document_upload is not added along with unwelcome'
            );

            $test_client_cr->status->upsert('unwelcome', 'system', 'potential corporate account');
            cmp_deeply(
                $c->tcall($method, {token => $token_cr})->{status},
                superbagof(qw(unwelcome allow_document_upload)),
                'allow_document_upload is automatically added along with unwelcome if account is locked for false info'
            );
            $test_client_cr->status->clear_unwelcome;

            $test_client_cr->status->set('cashier_locked', 'system', 'fake profile info');
            cmp_deeply(
                $c->tcall($method, {token => $token_cr})->{status},
                superbagof(qw(cashier_locked allow_document_upload)),
                'allow_document_upload is automatically added along with cashier_locked if account is locked for false info'
            );

            $test_client_cr->status->upsert('cashier_locked', 'system', 'For test purposes');
            cmp_deeply(
                $c->tcall($method, {token => $token_cr})->{status},
                superbagof(qw(cashier_locked)),
                'allow_document_upload is not added along with cashier_locked'
            );
            $test_client_cr->status->clear_cashier_locked;

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
                    p2p_poa_required              => 0,
                    p2p_status                    => "none",
                    status                        => superbagof(qw(document_needs_action)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => ["document", "identity"],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    }
                },
                'authentication page for POI and POA should be shown if the client is not age verified and needs action is set regardless of balance'
            );

            my $mocked_status = Test::MockModule->new(ref($test_client_cr->status));
            $mocked_status->mock(
                'age_verification',
                sub {
                    return {
                        staff_name         => 'system',
                        last_modified_date => Date::Utility->new()->datetime_ddmmmyy_hhmmss
                    };
                });
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
                    p2p_poa_required              => 0,
                    p2p_status                    => "none",
                    status                        => superbagof(qw(document_needs_action)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => ["document"],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    }
                },
                'authentication page should be shown for proof of address if needs action is set for age verified clients'
            );
            $mocked_status->unmock_all();

            subtest "Age verified client, do check for expiry of documents" => sub {
                # For age verified clients
                # we don't need to have a check for expiry of documents for svg

                my $mocked_client = Test::MockModule->new(ref($test_client_cr));
                my @latest_poi_by;
                $mocked_client->mock('latest_poi_by', sub { return @latest_poi_by });
                $mocked_status->mock(
                    'age_verification',
                    sub {
                        return +{
                            staff_name => 'gato',
                            reason     => 'test'
                        };
                    });
                $documents_uploaded = {
                    proof_of_identity => {
                        documents => {
                            $test_client_cr->loginid
                                . '_passport' => {
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                type        => 'passport',
                                format      => 'pdf',
                                id          => 2,
                                status      => 'uploaded'
                                },
                        },
                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                        is_expired  => 1,
                    },
                };

                $documents_expired = 1;
                $test_client_cr->set_authentication('ID_DOCUMENT', {status => 'pending'});
                $test_client_cr->save;
                my $documents              = $test_client_cr->documents->uploaded();
                my $is_poi_already_expired = $documents->{proof_of_identity}->{is_expired};
                ok !$test_client_cr->fully_authenticated,     'Not fully authenticated';
                ok $test_client_cr->status->age_verification, 'Age verified';
                ok $is_poi_already_expired,                   'POI expired';
                @latest_poi_by = ('manual');
                $result        = $c->tcall($method, {token => $token_cr});

                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "USD" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        p2p_poa_required              => 0,
                        p2p_status                    => "none",
                        status                        => noneof(qw(document_expired)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
                            document => {
                                status                 => "none",
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
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit - 1,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                        status               => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'expired',
                                    }}
                            },
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            income => {
                                status => 'none',
                            },
                            needs_verification => ['identity'],
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
                        },
                        cashier_validation => ['documents_expired'],
                    },
                    "authentication object is correct"
                );

                $documents_uploaded = undef;
                $documents_expired  = undef;
                $mocked_client->unmock_all();
                $mocked_status->unmock_all();
            };

            subtest 'Fully authenticated CR have to check for expired documents' => sub {
                my $mocked_client = Test::MockModule->new(ref($test_client_cr));
                my @latest_poi_by;
                $mocked_client->mock('latest_poi_by',       sub { return @latest_poi_by });
                $mocked_client->mock('fully_authenticated', sub { return 1 });
                $mocked_status->mock(
                    'age_verification',
                    sub {
                        return +{
                            staff_name => 'gato',
                            reason     => 'test'
                        };
                    });
                $documents_expired  = 1;
                $documents_uploaded = {
                    proof_of_address => {
                        documents => {
                            $test_client_cr->loginid
                                . '_bankstatement' => {
                                expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                                type        => 'bankstatement',
                                format      => 'pdf',
                                id          => 1,
                                status      => 'uploaded'
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
                                status      => 'uploaded'
                                },
                        },
                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                        is_expired  => 1,
                    },
                };

                # This test would be useless if this company authentication is mandatory
                my $mocked_lc = Test::MockModule->new('LandingCompany');
                $mocked_lc->mock(
                    'is_authentication_mandatory',
                    sub {
                        return 0;
                    });
                ok !$test_client_cr->landing_company->is_authentication_mandatory, 'Authentication is not mandatory';
                ok $test_client_cr->documents->expired(),                          'Client expiry is required';
                ok $test_client_cr->fully_authenticated,                           'Account is fully authenticated';
                @latest_poi_by = ('manual');
                $result        = $c->tcall($method, {token => $token_cr});
                $mocked_lc->unmock('is_authentication_mandatory');

                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "USD" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        p2p_poa_required              => 0,
                        p2p_status                    => "none",
                        status                        => superbagof(qw(allow_document_upload)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
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
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit - 1,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                        status               => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'expired',
                                    }}
                            },
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            income => {
                                status => 'none',
                            },
                            needs_verification => ['identity'],
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
                        },
                        cashier_validation => ['documents_expired'],
                    },
                    "authentication object is correct"
                );

                $documents_uploaded = undef;
                $documents_expired  = undef;
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
                    p2p_poa_required => 0,
                    p2p_status       => "none",
                    status => superbagof(qw(financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)),
                    risk_classification           => 'high',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => ["document", "identity"],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    },
                    cashier_validation => ['ASK_AUTHENTICATE', 'FinancialAssessmentRequired'],
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
                    p2p_poa_required              => 0,
                    p2p_status                    => "none",
                    status                        => superbagof(qw(age_verification allow_document_upload)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
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
                    p2p_poa_required => 0,
                    p2p_status       => "none",
                    status => superbagof(qw(age_verification authenticated financial_information_not_complete trading_experience_not_complete)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
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
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'verified',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
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
                    p2p_poa_required              => 0,
                    p2p_status                    => "none",
                    status                        => superbagof(qw()),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    }
                },
                'test if all manual status has been removed'
            );

        };

        subtest 'futher resubmission allowed' => sub {
            my $mocked_lc = Test::MockModule->new('LandingCompany');
            $mocked_lc->mock(
                'is_authentication_mandatory',
                sub {
                    return 0;
                });
            my $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply $result->{authentication}->{needs_verification}, noneof(qw/document identity/),     'Make sure needs verification is empty';
            cmp_deeply $result->{status},                               noneof(qw/allow_document_upload/), 'Make sure allow_document_upload is off';

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
                        p2p_poa_required              => 0,
                        p2p_status                    => "none",
                        status                        => superbagof(),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
                            document => {
                                status                 => "none",
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
                                status   => "none",
                                services => {
                                    onfido => {
                                        submissions_left     => $onfido_limit - 1,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                        status               => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'none',
                                    }}
                            },
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            income => {
                                status => 'none',
                            },
                            needs_verification => superbagof(qw(identity)),
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
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
                        p2p_poa_required              => 0,
                        p2p_status                    => "none",
                        status                        => superbagof(),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
                            document => {
                                status                 => "none",
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
                                status   => "none",
                                services => {
                                    onfido => {
                                        submissions_left     => $onfido_limit - 1,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                        status               => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'none',
                                    }}
                            },
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            income => {
                                status => 'none',
                            },
                            needs_verification => superbagof(qw(document)),
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
                        },
                    },
                );

                $test_client_cr->status->clear_allow_poa_resubmission;
            };

            $mocked_lc->unmock('is_authentication_mandatory');
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
                    p2p_poa_required => 0,
                    p2p_status       => "none",
                    status           => superbagof(
                        qw(allow_document_upload financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)
                    ),
                    risk_classification           => 'high',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Driving Licence',
                                        'National Health Insurance Card',
                                        'National Identity Card',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'AUT',
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => ["document", "identity"],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    },
                    cashier_validation => ['ASK_AUTHENTICATE', 'FinancialAssessmentRequired']
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
                    p2p_poa_required    => 0,
                    p2p_status          => "none",
                    status              => superbagof(qw(allow_document_upload financial_information_not_complete trading_experience_not_complete)),
                    risk_classification => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Driving Licence',
                                        'National Health Insurance Card',
                                        'National Identity Card',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'AUT',
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
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
                    p2p_poa_required              => 0,
                    p2p_status                    => "none",
                    status                        => superbagof(qw(financial_information_not_complete trading_experience_not_complete)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Driving Licence',
                                        'National Health Insurance Card',
                                        'National Identity Card',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'AUT',
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => ["document", "identity"],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
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
                $mocked_status->mock(
                    'age_verification',
                    sub {
                        return +{
                            staff_name => 'gato',
                            reason     => 'test'
                        };
                    });
                $documents_expired = 1;
                $mocked_client->mock('has_deposits', sub { return 1 });
                my @latest_poi_by;
                $mocked_client->mock('latest_poi_by', sub { return @latest_poi_by });
                $documents_uploaded = {
                    proof_of_identity => {
                        documents => {
                            $test_client_mlt->loginid
                                . '_passport' => {
                                expiry_date => Date::Utility->new->minus_time_interval('10d')->epoch,
                                type        => 'passport',
                                format      => 'pdf',
                                id          => 2,
                                status      => 'uploaded'
                                },
                        },
                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                        is_expired  => 1,
                    },
                };

                my $documents              = $test_client_mlt->documents->uploaded();
                my $is_poi_already_expired = $documents->{proof_of_identity}->{is_expired};
                ok !$test_client_mlt->fully_authenticated,     'Not fully authenticated';
                ok $test_client_mlt->status->age_verification, 'Age verified';
                ok $is_poi_already_expired,                    'POI expired';
                @latest_poi_by = ('manual');
                $result        = $c->tcall($method, {token => $token_mlt});
                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "EUR" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        p2p_poa_required              => 0,
                        p2p_status                    => "none",
                        status                        => superbagof(qw(allow_document_upload document_expired)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '1',
                        authentication                => {
                            document => {
                                status                 => "none",
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
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => [
                                            'Asylum Registration Card',
                                            'Driving Licence',
                                            'National Health Insurance Card',
                                            'National Identity Card',
                                            'Passport',
                                            'Residence Permit',
                                            'Visa'
                                        ],
                                        country_code        => 'AUT',
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'expired',
                                    }}
                            },
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            income => {
                                status => 'none',
                            },
                            needs_verification => superbagof(qw(identity)),
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
                        },
                        cashier_validation => ['documents_expired'],
                    },
                    "authentication object is correct"
                );

                $documents_uploaded = undef;
                $documents_expired  = undef;
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
                    p2p_poa_required => 0,
                    p2p_status       => "none",
                    status => superbagof(qw(financial_information_not_complete trading_experience_not_complete financial_assessment_not_complete)),
                    risk_classification           => 'high',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Driving Licence',
                                        'Immigration Status Document',
                                        'National Health Insurance Card',
                                        'National Identity Card',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'GBR',
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => ["document", "identity"],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
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
            $mocked_status->mock('age_verification', sub { return {reason => 'test reason', staff_name => 'system'} });
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
                    p2p_poa_required              => 0,
                    p2p_status                    => "none",
                    status                        => superbagof(qw(financial_information_not_complete trading_experience_not_complete)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '1',
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Driving Licence',
                                        'Immigration Status Document',
                                        'National Health Insurance Card',
                                        'National Identity Card',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'GBR',
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => ["document"],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
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
                    p2p_poa_required              => 0,
                    p2p_status                    => "none",
                    status                        => superbagof(qw(financial_information_not_complete trading_experience_not_complete)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => '0',
                    authentication                => {
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
                            status   => "verified",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => [
                                        'Asylum Registration Card',
                                        'Driving Licence',
                                        'Immigration Status Document',
                                        'National Health Insurance Card',
                                        'National Identity Card',
                                        'Passport',
                                        'Residence Permit',
                                        'Visa'
                                    ],
                                    country_code        => 'GBR',
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'verified',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    },
                    cashier_validation => ignore(),
                },
                'Dont allow for further resubmission if MX client is fully authenticated.'
            );

            $mocked_client->unmock_all;
            $mocked_status->unmock_all;

            subtest "Age verified client, check for expiry of documents" => sub {
                my $mocked_client = Test::MockModule->new('BOM::User::Client');
                $mocked_client->mock('has_deposits', sub { return 1 });
                my @latest_poi_by;
                $mocked_client->mock('latest_poi_by', sub { return @latest_poi_by });
                # For age verified clients
                # we will only check for iom and malta. (expiry of documents)

                $test_client_mx->set_authentication('ID_DOCUMENT', {status => 'pending'});
                $test_client_mx->save;
                $mocked_status->mock(
                    'age_verification',
                    sub {
                        return +{
                            staff_name => 'gato',
                            reason     => 'test'
                        };
                    });
                $documents_expired  = 1;
                $documents_uploaded = {
                    proof_of_identity => {
                        documents => {
                            $test_client_mx->loginid
                                . '_passport' => {
                                expiry_date => Date::Utility->new->minus_time_interval('10d')->epoch,
                                type        => 'passport',
                                format      => 'pdf',
                                id          => 2,
                                status      => 'uploaded'
                                },
                        },
                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                        is_expired  => 1,
                    },
                };

                my $documents              = $test_client_mx->documents->uploaded();
                my $is_poi_already_expired = $documents->{proof_of_identity}->{is_expired};
                ok !$test_client_mx->fully_authenticated,     'Not fully authenticated';
                ok $test_client_mx->status->age_verification, 'Age verified';
                ok $is_poi_already_expired,                   'POI expired';
                @latest_poi_by = ('manual');
                $result        = $c->tcall($method, {token => $token_mx});

                cmp_deeply(
                    $result,
                    {
                        currency_config => {
                            "GBP" => {
                                is_deposit_suspended    => 0,
                                is_withdrawal_suspended => 0,
                            }
                        },
                        p2p_poa_required              => 0,
                        p2p_status                    => "none",
                        status                        => superbagof(qw(allow_document_upload document_expired)),
                        risk_classification           => 'low',
                        prompt_client_to_authenticate => '1',
                        authentication                => {
                            document => {
                                status                 => "none",
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
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => [
                                            'Asylum Registration Card',
                                            'Driving Licence',
                                            'Immigration Status Document',
                                            'National Health Insurance Card',
                                            'National Identity Card',
                                            'Passport',
                                            'Residence Permit',
                                            'Visa'
                                        ],
                                        country_code        => 'GBR',
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'expired',
                                    }}
                            },
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            income => {
                                status => 'none',
                            },
                            needs_verification => superbagof(qw(identity)),
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
                        },
                        cashier_validation => ['ASK_CURRENCY', 'ASK_UK_FUNDS_PROTECTION', 'documents_expired'],
                    },
                    "authentication object is correct"
                );

                $documents_uploaded = undef;
                $documents_expired  = undef;
                $mocked_client->unmock_all();
                $mocked_status->unmock_all();
            };
        };
    };

    subtest "account authentication" => sub {
        subtest "fully authenicated" => sub {
            my $mocked_client = Test::MockModule->new(ref($test_client));
            my @latest_poi_by;
            $mocked_client->mock('latest_poi_by', sub { return @latest_poi_by });
            # mark as fully authenticated
            $test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
            $test_client->save;

            my $mocked_status = Test::MockModule->new(ref($test_client->status));
            $mocked_status->mock(
                'age_verification',
                sub {
                    return +{
                        staff_name => 'system',
                        reason     => 'test'
                    };
                });

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
                        p2p_poa_required => 0,
                        p2p_status       => "none",
                        status           => superbagof(qw(allow_document_upload age_verification authenticated financial_information_not_complete)),
                        risk_classification           => 'standard',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
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
                                status   => "verified",
                                services => {
                                    onfido => {
                                        submissions_left     => $onfido_limit - 1,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                        status               => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'verified',
                                    }}
                            },
                            income => {
                                status => "none",
                            },
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            needs_verification => [],
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
                        },
                        cashier_validation => ignore(),
                    },
                    'correct authenication object for authenticated client with valid documents'
                );
            };

            subtest "with expired documents" => sub {
                $documents_uploaded = {
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
                                status      => 'uploaded'
                                },
                        },
                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                        is_expired  => 1,
                    },
                };

                @latest_poi_by = ('manual');
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
                        p2p_poa_required              => 0,
                        p2p_status                    => "none",
                        status                        => superbagof(qw(age_verification authenticated financial_information_not_complete)),
                        risk_classification           => 'standard',
                        prompt_client_to_authenticate => '0',
                        authentication                => {
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
                                status      => "expired",
                                expiry_date => $result->{authentication}{identity}{expiry_date},
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit - 1,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                        status               => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'expired',
                                    }}
                            },
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            income => {
                                status => 'none',
                            },
                            needs_verification => ["identity"],
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
                        },
                        cashier_validation => ignore(),
                    },
                    'correct authentication object for authenticated client with expired documents'
                );

                $documents_uploaded = undef;
            };

            subtest "check for expired documents if landing company required that" => sub {
                $documents_uploaded = {
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
                                status      => 'uploaded'
                                },
                        },
                        expiry_date => Date::Utility->new->minus_time_interval('1d')->epoch,
                        is_expired  => 1,
                    },
                };

                my $method_response = $c->tcall($method, {token => $token});
                my $expected_result = {
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
                        status      => "expired",
                        expiry_date => re('\d+'),
                        services    => {
                            onfido => {
                                submissions_left     => $onfido_limit - 1,
                                last_rejected        => [],
                                documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                is_country_supported => 1,
                                country_code         => 'IDN',
                                reported_properties  => {},
                                status               => 'none',
                            },
                            idv => {
                                submissions_left    => $idv_limit,
                                last_rejected       => [],
                                reported_properties => {},
                                status              => 'none',
                            },
                            manual => {
                                status => 'expired',
                            }
                        },
                    },
                    ownership => {
                        status   => 'none',
                        requests => [],
                    },
                    income => {
                        status => 'none',
                    },
                    needs_verification => ['identity'],
                    attempts           => {
                        latest  => undef,
                        count   => 0,
                        history => []
                    },
                };

                my $result = $method_response->{authentication};
                cmp_deeply($result, $expected_result, "correct authenication object for authenticated client with expired documents");
                $documents_uploaded = undef;
            };

            $mocked_status->unmock_all;
            $mocked_client->unmock_all;
        };

        subtest "age verified" => sub {
            my $mocked_client = Test::MockModule->new(ref($test_client));
            my @latest_poi_by;
            $mocked_client->mock('latest_poi_by', sub { return @latest_poi_by });

            my $mocked_status = Test::MockModule->new(ref($test_client->status));
            $mocked_status->mock(
                'age_verification',
                sub {
                    return +{
                        staff_name => 'system',
                        reason     => 'test',
                    };
                });

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
                        p2p_poa_required              => 0,
                        p2p_status                    => "none",
                        status                        => superbagof(qw(age_verification financial_information_not_complete)),
                        risk_classification           => 'standard',
                        prompt_client_to_authenticate => 0,
                        authentication                => {
                            document => {
                                status                 => "none",
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
                                status   => "verified",
                                services => {
                                    onfido => {
                                        submissions_left     => $onfido_limit - 1,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                        status               => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'none',
                                    }}
                            },
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            income => {
                                status => 'none',
                            },
                            needs_verification => [],
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
                        },
                        cashier_validation => ignore(),
                    },
                    'correct authenication object for age verified client only'
                );
            };

            subtest "with expired documents" => sub {
                @latest_poi_by      = ('manual');
                $documents_uploaded = {
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
                        p2p_poa_required              => 0,
                        p2p_status                    => "none",
                        status                        => superbagof(qw(age_verification financial_information_not_complete)),
                        risk_classification           => 'standard',
                        prompt_client_to_authenticate => 0,
                        authentication                => {
                            identity => {
                                status      => "expired",
                                expiry_date => re('\d+'),
                                services    => {
                                    onfido => {
                                        submissions_left     => $onfido_limit - 1,
                                        last_rejected        => [],
                                        is_country_supported => 1,
                                        documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                        country_code         => 'IDN',
                                        reported_properties  => {},
                                        status               => 'none',
                                    },
                                    idv => {
                                        submissions_left    => $idv_limit,
                                        last_rejected       => [],
                                        reported_properties => {},
                                        status              => 'none',
                                    },
                                    manual => {
                                        status => 'expired',
                                    }}
                            },
                            document => {
                                status                 => "none",
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
                            ownership => {
                                status   => 'none',
                                requests => [],
                            },
                            income => {
                                status => 'none',
                            },
                            needs_verification => ["identity"],
                            attempts           => {
                                latest  => undef,
                                count   => 0,
                                history => []
                            },
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
            $documents_uploaded = undef;
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
                    p2p_poa_required              => 0,
                    p2p_status                    => "none",
                    status                        => superbagof(qw(financial_information_not_complete)),
                    risk_classification           => 'standard',
                    prompt_client_to_authenticate => 0,
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => 'none',
                        },
                        needs_verification => [],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    },
                    cashier_validation => ignore(),
                },
                'correct authenication object for unauthenticated client'
            );
        };

        subtest 'idv disallowed' => sub {
            my $mocked_client = Test::MockModule->new('BOM::User::Client');

            $test_client_cr->status->clear_allow_document_upload;
            my $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply($result->{status}, superbagof(qw(financial_information_not_complete)), 'no idv_disallowed if no allow_document_upload');

            $test_client_cr->status->setnx('unwelcome', 'system', 'reason');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply($result->{status}, superbagof(qw(idv_disallowed)), 'no idv_disallowed if no allow_document_upload');
            $test_client_cr->status->clear_unwelcome;

            $mocked_client->mock(aml_risk_classification => 'high');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result->{status},
                superbagof(qw(idv_disallowed financial_information_not_complete financial_assessment_not_complete)),
                'no idv_disallowed if cr account aml high risk'
            );
            $mocked_client->mock(aml_risk_classification => 'low');

            $test_client_cr->status->upsert('age_verification', 'system', 'verified');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply($result->{status}, superbagof(qw(allow_document_upload idv_disallowed)), 'idv_disallowed if client has age verified');
            $test_client_cr->status->clear_age_verification;

            $test_client_cr->status->upsert('allow_poi_resubmission', 'system', 'resubmission');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply($result->{status}, superbagof(qw(allow_document_upload idv_disallowed)),
                'idv_disallowed if client has allow_poi_resubmission');
            $test_client_cr->status->clear_allow_poi_resubmission;

            for my $reason (
                qw/FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT CRYPTO_TO_CRYPTO_TRANSFER_OVERLIMIT CRYPTO_TO_FIAT_TRANSFER_OVERLIMIT P2P_ADVERTISER_CREATED/)
            {
                $test_client_cr->status->upsert('allow_document_upload', 'system', $reason);
                $result = $c->tcall($method, {token => $token_cr});
                cmp_deeply($result->{status}, noneof(qw(idv_disallowed)), 'no idv_disallowed if allow_document_upload with allowed reason');
                cmp_deeply($result->{status}, superbagof(qw(allow_document_upload)), "correct statuses for reason $reason");
            }

            $test_client_cr->status->upsert('allow_document_upload', 'system', 'ANYTHING_ELSE');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply($result->{status}, noneof(qw(idv_disallowed)), 'idv allowed correctly for ANYTHING_ELSE');

            $mocked_client->mock('get_onfido_status', 'expired');
            $test_client_cr->status->upsert('allow_document_upload', 'system', 'P2P_ADVERTISER_CREATED');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result->{status},
                superbagof(qw(idv_disallowed allow_document_upload)),
                'idv not allowed correctly for because onfido docs are expired'
            );

            $mocked_client->mock('get_onfido_status', 'rejected');
            $test_client_cr->status->upsert('allow_document_upload', 'system', 'P2P_ADVERTISER_CREATED');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result->{status},
                superbagof(qw(idv_disallowed allow_document_upload)),
                'idv not allowed correctly for because onfido docs are expired'
            );
            $mocked_client->unmock('get_onfido_status');

            $mocked_client->mock('get_manual_poi_status', 'expired');
            $test_client_cr->status->upsert('allow_document_upload', 'system', 'P2P_ADVERTISER_CREATED');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result->{status},
                superbagof(qw(idv_disallowed allow_document_upload)),
                'idv not allowed correctly for because manual docs are expired'
            );

            $mocked_client->mock('get_manual_poi_status', 'rejected');
            $test_client_cr->status->upsert('allow_document_upload', 'system', 'P2P_ADVERTISER_CREATED');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result->{status},
                superbagof(qw(idv_disallowed allow_document_upload)),
                'idv not allowed correctly for because manual docs are expired'
            );

            $mocked_client->unmock('get_manual_poi_status');
            $test_client_cr->status->clear_allow_document_upload;
            $result = $c->tcall($method, {token => $token});
            cmp_deeply(
                $result->{status},
                superbagof(qw(idv_disallowed allow_document_upload financial_information_not_complete)),
                'idv not allowed for regulated landing companies'
            );

            $test_client_cr->status->set('age_verification', 'test', 'test');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result->{status},
                superbagof(qw(idv_disallowed allow_document_upload financial_information_not_complete)),
                'idv not allowed for age verified client'
            );

            $mocked_client->mock(get_idv_status => 'expired');
            $result = $c->tcall($method, {token => $token_cr});
            cmp_deeply(
                $result->{status},
                superbagof(qw(allow_document_upload financial_information_not_complete)),
                'idv allowed for age verified client and idv status expired'
            );

            $mocked_client->unmock_all();
        };

        subtest 'shared payment method' => sub {
            $documents_uploaded = undef;
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
                    p2p_poa_required              => 0,
                    p2p_status                    => "none",
                    status                        => superbagof(qw(cashier_locked shared_payment_method)),
                    risk_classification           => 'low',
                    prompt_client_to_authenticate => 0,
                    authentication                => {
                        document => {
                            status                 => "none",
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
                            status   => "none",
                            services => {
                                onfido => {
                                    submissions_left     => $onfido_limit - 1,
                                    last_rejected        => [],
                                    is_country_supported => 1,
                                    documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                                    country_code         => 'IDN',
                                    reported_properties  => {},
                                    status               => 'none',
                                },
                                idv => {
                                    submissions_left    => $idv_limit,
                                    last_rejected       => [],
                                    reported_properties => {},
                                    status              => 'none',
                                },
                                manual => {
                                    status => 'none',
                                }}
                        },
                        ownership => {
                            status   => 'none',
                            requests => [],
                        },
                        income => {
                            status => "none",
                        },
                        needs_verification => ["identity"],
                        attempts           => {
                            latest  => undef,
                            count   => 0,
                            history => []
                        },
                    },
                    cashier_validation => ['cashier_locked_status'],
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
            p2p_poa_required              => 0,
            p2p_status                    => "none",
            status                        => noneof(qw(authenticated)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '0',
            authentication                => {
                document => {
                    status                 => "none",
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
                    status   => "none",
                    services => {
                        onfido => {
                            submissions_left     => $onfido_limit,
                            last_rejected        => [],
                            is_country_supported => 0,
                            documents_supported  => [],
                            country_code         => 'ATA',
                            reported_properties  => {},
                            status               => 'none',
                        },
                        idv => {
                            submissions_left    => $idv_limit,
                            last_rejected       => [],
                            reported_properties => {},
                            status              => 'none',
                        },
                        manual => {
                            status => 'none',
                        }}
                },
                ownership => {
                    status   => 'none',
                    requests => [],
                },
                income => {
                    status => 'none',
                },
                needs_verification => [],
                attempts           => {
                    latest  => undef,
                    count   => 0,
                    history => []
                },
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
            p2p_poa_required              => 0,
            p2p_status                    => "none",
            status                        => noneof(qw(authenticated)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '0',
            authentication                => {
                document => {
                    status                 => "none",
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
                    status   => "none",
                    services => {
                        onfido => {
                            submissions_left     => $onfido_limit,
                            last_rejected        => [],
                            is_country_supported => 1,
                            documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                            country_code         => 'IDN',
                            reported_properties  => {},
                            status               => 'none',
                        },
                        idv => {
                            submissions_left    => $idv_limit,
                            last_rejected       => [],
                            reported_properties => {},
                            status              => 'none',
                        },
                        manual => {
                            status => 'none',
                        }}
                },
                ownership => {
                    status   => 'none',
                    requests => [],
                },
                income => {
                    status => 'none',
                },
                needs_verification => [],
                attempts           => {
                    latest  => undef,
                    count   => 0,
                    history => []
                },
            }
        },
        'is_country_supported uses POB as priority when checking'
    );
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
    my $poi_dob_mismatch;
    my $reasons       = [];
    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    my $onfido_document_sub_result;
    my $onfido_check_result;

    $onfido_mock->mock(
        'get_latest_check',
        sub {
            return {
                report_document_status     => 'complete',
                report_document_sub_result => $onfido_document_sub_result,
                user_check                 => {
                    result => $onfido_check_result,
                },
            };
        });

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
    $client_mock->mock(
        'get_onfido_status',
        sub {
            return $poi_status;
        });

    my $provider;
    $client_mock->mock(
        'latest_poi_by',
        sub {
            return $provider;
        });

    my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
    $status_mock->mock(
        'poi_name_mismatch',
        sub {
            return $poi_name_mismatch;
        });
    $status_mock->mock(
        'poi_dob_mismatch',
        sub {
            return $poi_dob_mismatch;
        });

    my %catalog = BOM::Platform::Utility::rejected_onfido_reasons_error_codes()->%*;
    my $tests   = [map { +{reasons => [$_], poi_status => 'rejected', expected => [$catalog{$_}], test => "Testing $_",} } keys %catalog];

    # Adding more cases

    push $tests->@*,
        {
        reasons          => [],
        expected         => [],
        test             => 'From our rules (poi_dob_mismatch is set but not by onfido)',
        poi_status       => 'verified',
        poi_dob_mismatch => 1,
        provider         => 'idv'
        };

    push $tests->@*,
        {
        reasons           => [],
        expected          => [],
        test              => 'From our rules (poi_name_mismatch is set but not by onfido)',
        poi_status        => 'verified',
        poi_name_mismatch => 1,
        provider          => 'idv'
        };

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
        expected   => ["DataComparisonName"],
        test       => 'Duplicated message is reported once',
        poi_status => 'suspected',
        };

    push $tests->@*,
        {
        reasons    => ['data_comparison.first_name', 'age_validation.minimum_accepted_age', 'selfie', 'garbage'],
        expected   => ["DataComparisonName", "AgeValidationMinimumAcceptedAge", "SelfieRejected"],
        test       => 'Multiple messages reported',
        poi_status => 'suspected',
        };

    push $tests->@*,
        {
        reasons    => ['data_comparison.date_of_birth'],
        expected   => ["DataComparisonDateOfBirth"],
        test       => 'Date of birth issues',
        poi_status => 'rejected',
        };

    push $tests->@*,
        {
        poi_dob_mismatch => 1,
        reasons          => [],
        expected         => ["DataComparisonDateOfBirth"],
        test             => 'Date of birth mismatch',
        poi_status       => 'rejected',
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
        expected          => ["DataComparisonName"],
        test              => 'From our rules (poi_name_mismatch)',
        poi_status        => 'suspected',
        poi_name_mismatch => 1,
        };

    push $tests->@*,
        {
        reasons           => [],
        expected          => ["DataComparisonName"],
        test              => 'From our rules (poi_name_mismatch)',
        poi_status        => 'verified',
        poi_name_mismatch => 1,
        };

    push $tests->@*,
        {
        reasons           => [],
        expected          => [],
        test              => 'From our rules (poi_name_mismatch => undef)',
        poi_status        => 'expired',
        poi_name_mismatch => undef,
        };

    for my $test ($tests->@*) {
        $reasons           = $test->{reasons};
        $poi_status        = $test->{poi_status};
        $poi_name_mismatch = $test->{poi_name_mismatch};
        $poi_dob_mismatch  = $test->{poi_dob_mismatch};
        $provider          = $test->{provider} // 'onfido';

        if ($poi_status eq 'rejected') {
            $onfido_document_sub_result = 'rejected';
            $onfido_check_result        = 'consider';
        } elsif ($poi_status eq 'suspected') {
            $onfido_document_sub_result = 'suspected';
            $onfido_check_result        = 'consider';
        } elsif ($poi_status eq 'verified') {
            $onfido_document_sub_result = undef;
            $onfido_check_result        = 'clear';
        }

        my $result        = $c->tcall($method, {token => $token_rejected});
        my $last_rejected = $result->{authentication}->{identity}->{services}->{onfido}->{last_rejected};
        is $result->{authentication}->{identity}->{services}->{onfido}->{status}, $poi_status, "Got expected onfido status=$poi_status";
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
    $documents_uploaded = undef;
    my $email = 'social' . rand(999) . '@binary.com';

    BOM::Platform::Account::Virtual::create_account({
            details => {
                'client_password'   => '418508.727020996',
                'source'            => '7',
                'email'             => $email,
                'residence'         => 'id',
                'has_social_signup' => 1,
                'brand_name'        => 'deriv',
                'account_type'      => 'binary',
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
        $email,
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
            status                   => bag(
                qw(allow_document_upload dxtrade_password_not_set social_signup financial_information_not_complete mt5_additional_kyc_required mt5_password_not_set trading_experience_not_complete)
            ),
            currency_config => {
                'USD' => {
                    is_deposit_suspended    => 0,
                    is_withdrawal_suspended => 0
                }
            },
            p2p_poa_required              => 0,
            p2p_status                    => "none",
            prompt_client_to_authenticate => 0,
            risk_classification           => 'low',
            authentication                => {
                identity => {
                    services => {
                        onfido => {
                            submissions_left     => 1,
                            is_country_supported => 1,
                            last_rejected        => [],
                            documents_supported  => ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'],
                            country_code         => 'IDN',
                            reported_properties  => {},
                            status               => 'none',
                        },
                        idv => {
                            submissions_left    => $idv_limit,
                            last_rejected       => [],
                            reported_properties => {},
                            status              => 'none',
                        },
                        manual => {
                            status => 'none',
                        }
                    },
                    status => 'none'
                },
                ownership => {
                    status   => 'none',
                    requests => [],
                },
                income => {
                    status => "none",
                },
                needs_verification => [],
                attempts           => {
                    latest  => undef,
                    count   => 0,
                    history => []
                },
                document => {
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

subtest 'affiliate code of conduct' => sub {
    my $user = BOM::User->create(
        email    => 'aff123@deriv.com',
        password => 'cooltobeanaffiliate',
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $user->add_client($client);

    $client->user->set_affiliate_id('aff123');
    is $client->user->affiliate_coc_approval_required, undef, 'new affiliate, coc_approval is undef';

    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall($method, {token => $token});

    cmp_deeply(
        $result->{status},
        [
            'allow_document_upload',       'cashier_locked',
            'dxtrade_password_not_set',    'financial_information_not_complete',
            'mt5_additional_kyc_required', 'mt5_password_not_set',
            'trading_experience_not_complete'
        ],
        "needs_affiliate_coc_approval status is not added when code_of_conduct_approval is undef"
    );

    $client->user->set_affiliate_coc_approval(0);
    is $client->user->affiliate_coc_approval_required, 1, 'coc_approval is required';

    $result = $c->tcall($method, {token => $token});

    cmp_deeply(
        $result->{status},
        [
            'allow_document_upload', 'cashier_locked', 'dxtrade_password_not_set',
            'financial_information_not_complete', 'mt5_additional_kyc_required',
            'mt5_password_not_set',
            'needs_affiliate_coc_approval', 'trading_experience_not_complete',

        ],
        "needs_affiliate_coc_approval status is added when code_of_conduct_approval is 0"
    );

    $client->user->set_affiliate_coc_approval(1);
    is $client->user->affiliate_coc_approval_required, 0, 'coc_approval is not required';

    $result = $c->tcall($method, {token => $token});

    cmp_deeply(
        $result->{status},
        [
            'allow_document_upload',       'cashier_locked',
            'dxtrade_password_not_set',    'financial_information_not_complete',
            'mt5_additional_kyc_required', 'mt5_password_not_set',
            'trading_experience_not_complete'
        ],
        "needs_affiliate_coc_approval status is removed when code_of_conduct_approval is 1"
    );
};

subtest 'clients withdrawal-locked for high AML risk' => sub {
    my $user = BOM::User->create(
        email    => 'high_aml_withdrawal_locked@deriv.com',
        password => '1234pass',
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client->account('USD');
    $user->add_client($client);
    my $token = $m->create_token($client->loginid, 'test token');

    for my $risk_level (qw/low standard/) {
        $client->status->set('withdrawal_locked',     'test', 'Pending authentication or FA');
        $client->status->set('allow_document_upload', 'test', 'BECOME_HIGH_RISK');
        $client->aml_risk_classification($risk_level);
        $client->save;

        my $result = $c->tcall($method, {token => $token});
        cmp_deeply $result->{cashier_validation}, ["ASK_AUTHENTICATE", "FinancialAssessmentRequired", "withdrawal_locked_status"],
            "Both POI and FA flags are returned - $risk_level risk client";

        # authenticated client
        my $mock_client = Test::MockModule->new('BOM::User::Client');
        $mock_client->redefine(fully_authenticated => 1);

        $result = $c->tcall($method, {token => $token});
        cmp_deeply $result->{cashier_validation}, ["FinancialAssessmentRequired", "withdrawal_locked_status"],
            "Only FA flags is returned if client is authenticated";
        $mock_client->unmock('fully_authenticated');

        # financial assesslemt
        $mock_client->redefine(is_financial_assessment_complete => 1);

        $result = $c->tcall($method, {token => $token});
        cmp_deeply $result->{cashier_validation}, ["ASK_AUTHENTICATE", "withdrawal_locked_status"], "Only POI flags is returned if FA is complete";
        $mock_client->unmock('is_financial_assessment_complete');

        # client locked for other reason
        $client->status->clear_allow_document_upload;
        $client->status->set('allow_document_upload', 'test', 'some other reason');
        $result = $c->tcall($method, {token => $token});
        cmp_deeply $result->{cashier_validation}, ["withdrawal_locked_status"], "No flag if the reason for doc upload reason is something else";

        $client->status->clear_allow_document_upload;
        $client->status->clear_withdrawal_locked;
        $mock_client->unmock_all;
    }
};

$documents_mock->unmock_all;

done_testing();
