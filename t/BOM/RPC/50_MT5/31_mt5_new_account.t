use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my $m                 = BOM::Platform::Token::API->new;
my %ACCOUNTS          = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS           = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data    = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;
my %financial_data_mf = %Test::BOM::RPC::Accounts::FINANCIAL_DATA_MF;

my $mt5_config = BOM::Config::Runtime->instance->app_config->system->mt5;
$mt5_config->suspend->real->p01_ts03->all(0);
$mt5_config->load_balance->demo->all->p01_ts02(0);
$mt5_config->load_balance->demo->all->p01_ts03(0);
$mt5_config->suspend->real->p02_ts02->all(0);
$mt5_config->suspend->real->p01_ts02->all(0);

subtest 'create mt5 client with different currency' => sub {
    subtest 'svg' => sub {
        my $new_email  = $DETAILS{email};
        my $new_client = create_client('CR');
        my $token      = $m->create_token($new_client->loginid, 'test token 2');
        $new_client->set_default_account('EUR');
        $new_client->email($new_email);

        my $user = BOM::User->create(
            email    => $new_email,
            password => 's3kr1t',
        );
        $user->update_trading_password($DETAILS{password}{main});
        $user->add_client($new_client);

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type => 'gaming',
                email        => $new_email,
                name         => $DETAILS{name},
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            },
        };

        my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
        is $result->{account_type}, 'gaming';
        is $result->{login},        'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'};

        my $new_client_vr = create_client('VRTC');
        $new_client_vr->set_default_account('GBP');
        $token = $m->create_token($new_client_vr->loginid, 'test token 2');
        $user->add_client($new_client_vr);

        $params->{token} = $token;

        $params->{args}->{account_type} = 'demo';
        $result = $c->call_ok($method, $params)->has_no_error->result;
        is $result->{account_type}, 'demo';
        is $result->{login},        'MTD' . $ACCOUNTS{'demo\p01_ts01\synthetic\svg_std_usd'};
    };

    subtest 'mf - country=gb' => sub {
        my $client    = create_client('MF', undef, {residence => 'gb'});
        my $new_email = 'mf+eur@binary.com';
        $client->set_default_account('EUR');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('gb');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data_mf)});
        $client->save();

        my $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->update_trading_password($DETAILS{password}{main});
        $user->add_client($client);

        my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type     => 'financial',
                mt5_account_type => 'financial',
                email            => $new_email,
                name             => $DETAILS{name},
                mainPassword     => $DETAILS{password}{main},
                leverage         => 100,
            },
        };

        $c->call_ok($method, $params)->has_error->error_code_is('InvalidAccountRegion')
            ->error_message_is('Sorry, account opening is unavailable in your region.');
    };

    subtest 'mf - country=de' => sub {
        my $client    = create_client('MF', undef, {residence => 'de'});
        my $new_email = 'mfde+gbp@binary.com';
        $client->set_default_account('GBP');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('de');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data_mf)});
        $client->save();

        my $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->update_trading_password($DETAILS{password}{main});
        $user->add_client($client);

        my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type     => 'financial',
                mt5_account_type => 'financial',
                email            => $new_email,
                name             => $DETAILS{name},
                mainPassword     => $DETAILS{password}{main},
                leverage         => 100,
            },
        };

        my $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'financial';
        is $result->{login},        'MTR' . $ACCOUNTS{'real\p01_ts01\financial\maltainvest_std-hr_gbp'};

        $client    = create_client('MF', undef, {residence => 'de'});
        $new_email = 'mfde+usd@binary.com';
        $client->set_default_account('USD');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('de');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data_mf)});
        $client->save();

        $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->update_trading_password($DETAILS{password}{main});
        $user->add_client($client);
        $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
        $params->{token} = $token;

        $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'financial';
        is $result->{login},        'MTR' . $ACCOUNTS{'real\p01_ts01\financial\maltainvest_std-hr_usd'};

        $client    = create_client('MF', undef, {residence => 'de'});
        $new_email = 'mfde+eur@binary.com';
        $client->set_default_account('EUR');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('de');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data_mf)});
        $client->save();

        $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->update_trading_password($DETAILS{password}{main});
        $user->add_client($client);
        $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        $params->{token} = $token;
        $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'financial';
        is $result->{login},        'MTR' . $ACCOUNTS{'real\p01_ts01\financial\maltainvest_std-hr_eur'};

        my $new_client_vr = create_client('VRTC', undef, {residence => 'de'});
        $new_client_vr->set_default_account('USD');
        $token = $m->create_token($new_client_vr->loginid, 'test token 2');
        $user->add_client($new_client_vr);

        $params->{token} = $token;
        $params->{args}->{account_type} = 'demo';
        delete $params->{args}->{currency};
        $result = $c->call_ok($method, $params)->has_no_error->result;
        is $result->{account_type}, 'demo';
        is $result->{login},        'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\maltainvest_std_eur'};
    };

    subtest 'mf - counrty=de no real' => sub {
        my $client    = create_client('VRTC', undef, {residence => 'de'});
        my $new_email = 'vrtcde+usd@binary.com';
        $client->set_default_account('USD');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('de');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data_mf)});
        $client->save();

        my $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->update_trading_password($DETAILS{password}{main});
        $user->add_client($client);
        my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type     => 'demo',
                mt5_account_type => 'financial',
                email            => $new_email,
                name             => $DETAILS{name},
                mainPassword     => $DETAILS{password}{main},
                leverage         => 100,
            },
        };

        my $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'demo';
        is $result->{login},        'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\maltainvest_std_eur'};
    };
};

subtest 'auto b-booking' => sub {
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(fully_authenticated => sub { return 1 });
    my $new_email  = 'abc' . $DETAILS{email};
    my $new_client = create_client('CR');
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('EUR');
    $new_client->email($new_email);
    $new_client->aml_risk_classification('low');
    $new_client->account_opening_reason('speculative');
    $new_client->tax_residence('id');
    $new_client->tax_identification_number('111-222-333');
    $new_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
    $new_client->save();

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($DETAILS{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password}{main},
            leverage     => 100,
        },
    };

    note('set suspend auto b-book to true');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_svg_financial(1);
    my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'gaming';
    is $result->{login}, 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'}, 'gaming account not affected';

    $params->{args}->{account_type}     = 'financial';
    $params->{args}->{mt5_account_type} = 'financial';
    $result                             = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'financial';
    is $result->{login}, 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std-hr_usd'}, 'routed to financial high risk';

    $params->{args}->{mt5_account_type} = 'financial_stp';
    $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'financial';
    is $result->{login}, 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'}, 'financial stp account no high risk flag';

    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_svg_financial(0);
};

subtest 'real & demo split on account creation' => sub {
    my $new_email  = 'cr+' . $DETAILS{email};
    my $new_client = create_client('CR', undef, {residence => 'za'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($DETAILS{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password}{main},
            leverage     => 100,
        },
    };

    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p02_ts02->all(1);
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(0);
    my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'gaming';
    is $result->{login},        'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\svg_std_usd\01'};

    note("disable real02 trade server's API");
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(1);
    $params->{args}->{account_type} = 'demo';
    $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'demo';
    is $result->{login},        'MTD' . $ACCOUNTS{'demo\p01_ts01\synthetic\svg_std_usd'};
};

SKIP: {
    skip "Technical account creation for Affiliates is not ready yet.";
    subtest 'open mt5 account from CRA client' => sub {
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p02_ts02->all(0);

        my $password = 'Abcd33!@';
        my $hash_pwd = BOM::User::Password::hashpw($password);
        my $email    = 'new_aff' . rand(999) . '@binary.com';
        my $user     = BOM::User->create(
            email          => $email,
            password       => $hash_pwd,
            email_verified => 1,
        );
        my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            email       => $email,
            residence   => 'br',
        });

        my $auth_token = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');
        my $params     = {
            args => {
                date_of_birth  => '1989-10-10',
                affiliate_plan => 'turnover',
                residence      => 'br',
                address_line_1 => 'nowhere',
                affiliate_plan => 'turnover',
                first_name     => 'test',
                last_name      => 'asdf',
                currency       => 'USD',
            },
            token => $auth_token,
        };

        my $result = $c->call_ok('affiliate_add_person', $params)->has_no_system_error->has_no_error()->result;

        my $mt5_args;
        my $mt5_mock = Test::MockModule->new('BOM::MT5::User::Async');
        $mt5_mock->mock(
            'create_user',
            sub {
                ($mt5_args) = @_;
                return $mt5_mock->original('create_user')->(@_);
            });

        my $aff_loginid = $result->{client_id};
        my $aff_token   = BOM::Platform::Token::API->new->create_token($aff_loginid, 'aff token');

        $params = {
            token => $aff_token,
            args  => {
                new_password => $DETAILS{password}{main},
                platform     => 'mt5'
            },
        };

        # First we need to set up a trading password for MT5
        $c->call_ok('trading_platform_password_change', $params)->has_no_system_error->has_no_error();

        $params->{args} = {
            mainPassword => 'Efgh4567',
            account_type => 'gaming',
        };
        # Now we can create the account
        $result = $c->call_ok('mt5_new_account', $params)->has_no_system_error->has_no_error()->result;

        is $result->{currency},     'USD',    'USD currency';
        is $result->{account_type}, 'gaming', 'Gaming account type';
        ok $result->{login} =~ /^MTR.*$/, 'MTR login';
        is $mt5_args->{group},  'real\p02_ts02\synthetic\seychelles_ib_usd', 'Expected group for dsl';
        is $mt5_args->{rights}, '0x0000000000000004',                        'Expected user rights';
        $mt5_mock->unmock_all;

        $c->call_ok('mt5_new_account', $params)->has_error->error_code_is('MT5CreateUserError')
            ->error_message_is(
            "An account already exists with the information you provided. If you've forgotten your username or password, please contact us.");

        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p02_ts02->all(1);
    };
}

subtest 'check correct reason is assigned upon mt5 acc creation' => sub {
    my $test_client = create_client('CR');
    my $new_email   = 'topside+' . $DETAILS{email};

    $test_client->email($new_email);
    $test_client->set_default_account('USD');
    $test_client->binary_user_id(1);

    $test_client->set_authentication('ID_DOCUMENT', {status => 'pending'});
    $test_client->save;

    my $password = 's3kr1t';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    my $user     = BOM::User->create(
        email    => $new_email,
        password => $hash_pwd,
    );
    $user->update_trading_password($DETAILS{password}{main});
    $user->add_client($test_client);

    my %basic_details = (
        place_of_birth            => "af",
        tax_residence             => "af",
        tax_identification_number => "1122334455",
        account_opening_reason    => "testing"
    );

    $test_client->$_($basic_details{$_}) for keys %basic_details;
    $test_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
    $test_client->save;

    my $token = $m->create_token($test_client->loginid, 'test token');

    ok !$test_client->status->allow_document_upload, 'allow_document_upload status not present';

    my $method = 'mt5_new_account';
    my $params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'mt',
            email            => $new_email,
            name             => 'cat',
            mainPassword     => $DETAILS{password}{main},
            leverage         => 100,
            dry_run          => 1,
            mt5_account_type => 'financial_stp',
            company          => 'labuan'
        },
    };
    my $doc_mock = Test::MockModule->new('BOM::User::Client');
    $doc_mock->mock(
        'get_poa_status',
        sub {
            return 'pending';
        });

    $c->call_ok($method, $params);

    $test_client->status->_build_all;
    ok $test_client->status->allow_document_upload, 'allow_document_upload status set';
    is $test_client->status->reason('allow_document_upload'), 'MT5_ACCOUNT_IS_CREATED', 'reason for landing company Labuan is set correctly ';

    $params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'mt',
            email            => $new_email,
            name             => 'cat',
            mainPassword     => $DETAILS{password}{main},
            leverage         => 100,
            dry_run          => 1,
            mt5_account_type => 'financial',
            company          => 'vanuatu'
        },
    };

    $doc_mock->mock(
        'get_poa_status',
        sub {
            return 'pending';
        });

    $c->call_ok($method, $params);

    $test_client->status->_build_all;
    ok $test_client->status->allow_document_upload, 'allow_document_upload status set';
    is $test_client->status->reason('allow_document_upload'), 'MT5_DVL_ACCOUNT_IS_CREATED', 'reason for landing company Vanuatu is set correctly ';

    $params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'mt',
            email            => $new_email,
            name             => 'cat',
            mainPassword     => $DETAILS{password}{main},
            leverage         => 100,
            dry_run          => 1,
            mt5_account_type => 'financial',
            company          => 'bvi'
        },
    };

    $doc_mock->mock(
        'get_poa_status',
        sub {
            return 'pending';
        });

    $c->call_ok($method, $params)->result;

    $test_client->status->_build_all;
    ok $test_client->status->allow_document_upload, 'allow_document_upload status set';
    is $test_client->status->reason('allow_document_upload'), 'MT5_DBVI_ACCOUNT_IS_CREATED', 'reason for landing company BVI is set correctly ';
};

done_testing();
