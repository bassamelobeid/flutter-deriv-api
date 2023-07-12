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
use BOM::Config::Runtime;

use Test::BOM::RPC::Accounts;

# disable routing to demo p01_ts02
my $p01_ts02_load = BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02;
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02(0);

# disable routing to demo p01_ts03
my $p01_ts03_load = BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03;
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03(0);

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %accounts          = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %details           = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data    = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;
my %financial_data_mf = %Test::BOM::RPC::Accounts::FINANCIAL_DATA_MF;
# Setup a test user
my $test_client    = create_client('CR');
my $test_client_vr = create_client('VRTC');

$test_client->email($details{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id(1);

$test_client_vr->email($details{email});
$test_client_vr->set_default_account('USD');

$test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
$test_client->save;

$test_client_vr->save;

my $password = 's3kr1t';
my $hash_pwd = BOM::User::Password::hashpw($password);
my $user     = BOM::User->create(
    email    => $details{email},
    password => $hash_pwd,
);
$user->update_trading_password($details{password}{main});
$user->add_client($test_client);
$user->add_client($test_client_vr);

my %basic_details = (
    place_of_birth            => "af",
    tax_residence             => "af",
    tax_identification_number => "1122334455",
    account_opening_reason    => "testing"
);

$test_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
$test_client->save;

my $m        = BOM::Platform::Token::API->new;
my $token    = $m->create_token($test_client->loginid,    'test token');
my $token_vr = $m->create_token($test_client_vr->loginid, 'test token');

subtest 'new account with invalid main or investor password format' => sub {
    my $method                   = 'mt5_new_account';
    my $wrong_formatted_password = 'abc123';
    my $params                   = {
        language => 'EN',
        token    => $token,
        args     => {
            email            => $details{email},
            name             => $details{name},
            account_type     => "demo",
            address          => "Dummy address",
            city             => "Valletta",
            company          => "Deriv Limited",
            country          => "mt",
            mainPassword     => "abc123",
            mt5_account_type => "financial",
            phone            => "+6123456789",
            phonePassword    => "AbcDv1234",
            state            => "Valleta",
            zipCode          => "VLT 1117",
            investPassword   => "AbcDv12345",
            mainPassword     => $wrong_formatted_password,
            leverage         => 100,
            company          => 'svg'
        },
    };

    $c->call_ok($method, $params)->has_error('error code for mt5_new_account wrong password formatting')
        ->error_code_is('IncorrectMT5PasswordFormat', 'error code for mt5_new_account wrong password formatting')
        ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'error code for mt5_new_account wrong password formatting');

    $params->{args}->{mainPassword}   = 'ABCDE123';
    $params->{args}->{investPassword} = 'ABCDEFGE';
    $c->call_ok($method, $params)->has_error('error code for mt5_new_account wrong investor password formatting')
        ->error_code_is('IncorrectMT5PasswordFormat', 'error code for mt5_new_account wrong investor password formatting')
        ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'error code for mt5_new_account wrong investor password formatting');
};

subtest 'new account with missing signup fields' => sub {
    # only Labuan has the signup (phone) requirement

    $test_client->status->set('crs_tin_information', 'system', 'testing something');
    $test_client->phone('');
    $test_client->save;

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp',
            country          => 'mt',
            email            => $details{email},
            name             => $details{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $details{password}{main},
            leverage         => 100,
            company          => 'labuan'
        },
    };

    $c->call_ok($method, $params)->has_error('error from missing signup details')
        ->error_code_is('ASK_FIX_DETAILS', 'error code for missing basic details')
        ->error_details_is({missing => ['phone', 'account_opening_reason']}, 'missing field in response details');

    $test_client->status->clear_crs_tin_information;
    $test_client->phone('12345678');
    $test_client->account_opening_reason('no reason');
    $test_client->save;
};

subtest 'new account' => sub {
    $test_client->user->update_trading_password($details{password}{main});
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            country      => 'mt',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
            company      => 'svg'
        },
    };
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account without investPassword');
    is($c->result->{login},           'MTR' . $accounts{'real\p01_ts03\synthetic\svg_std_usd\01'}, 'result->{login}');
    is($c->result->{balance},         0,                                                           'Balance is 0 upon creation');
    is($c->result->{display_balance}, '0.00',                                                      'Display balance is "0.00" upon creation');

    $c->call_ok($method, $params)->has_error('error from duplicate mt5_new_account')
        ->error_code_is('MT5CreateUserError', 'error code for duplicate mt5_new_account');
};

subtest 'new account dry_run' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            country      => 'mt',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
            dry_run      => 1,
            company      => 'svg'
        },
    };
    $c->call_ok($method, $params)->has_no_error('mt5 new account dry run only runs validations');
    is($c->result->{balance},         0,      'Balance is 0 upon dry run');
    is($c->result->{display_balance}, '0.00', 'Display balance is "0.00" upon dry run');
    is($c->result->{currency},        'USD',  'Currency is "USD" upon dry run');
};

subtest 'new account with account in highRisk groups' => sub {
    my $mock_mt5_rpc = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    my $mock_mt5     = Test::MockModule->new('BOM::MT5::User::Async');

    # Mocking get_user to return undef to make sure user dont have any derivez account yet
    $mock_mt5->mock('get_user', sub { return 'undef'; });

    my $new_email  = 'highrisk' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'id'});
    my $token      = $m->create_token($new_client->loginid, 'test token');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    subtest 'corresponding high risk group exists' => sub {
        # Mocking get_user to return undef to make sure user dont have any derivez account yet
        $mock_mt5->mock('get_user', sub { return 'undef'; });

        # Mocking create_user to create a new mt5 hr user
        $mock_mt5->mock('create_user', sub { return Future->done({login => "MTR21000004"}); });

        # We need to set auto_Bbook_bvi_financial to false to get the user as HR
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_svg_financial(1);

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type     => 'gaming',
                country          => 'id',
                email            => $details{email},
                mt5_account_type => 'financial',
                name             => $details{name},
                mainPassword     => $details{password}{main},
                leverage         => 100,
                company          => 'svg'
            },
        };

        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
        $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account without investPassword');
        is $c->result->{login}, 'MTR' . $accounts{'real\p01_ts02\synthetic\svg_std-hr_usd'}, 'group changed to high risk';
    };

    subtest 'corresponding high risk group does not exist' => sub {
        $mock_mt5_rpc->mock(
            get_mt5_account_type_config => sub {
                my ($group) = @_;

                return undef if $group =~ /\-hr/;
                return $mock_mt5_rpc->original('get_mt5_account_type_config')->($group);
            });

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type     => 'financial',
                country          => 'id',
                email            => $details{email},
                name             => $details{name},
                mainPassword     => $details{password}{main},
                leverage         => 100,
                mt5_account_type => 'financial',
                company          => 'svg'
            },
        };

        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
        $c->call_ok($method, $params)->has_error('high risk group does not exist for corresponding group')
            ->error_code_is('PermissionDenied', 'error code for mt5_new_account with navailable high risk group')
            ->error_message_is('Permission denied.');
    };

    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_svg_financial(0);

    $mock_mt5_rpc->unmock_all();
    $mock_mt5->unmock_all();
};

subtest 'status allow_document_upload is added upon mt5 create account dry_run advanced' => sub {
    my $ID_DOCUMENT = $test_client->get_authentication('ID_DOCUMENT')->status;

    $test_client->set_authentication('ID_DOCUMENT', {status => 'pending'});
    $test_client->tax_residence('mt');
    $test_client->tax_identification_number('111222333');
    $test_client->save;
    ok !$test_client->fully_authenticated, 'Not fully authenticated';
    my $method = 'get_account_status';
    my $params = {token => $token};
    $c->call_ok($method, $params);
    my $status = $c->result->{status};

    ok !$test_client->status->allow_document_upload, 'allow_document_upload status not present';

    $method = 'mt5_new_account';
    $params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'mt',
            email            => $details{email},
            name             => $details{name},
            mainPassword     => $details{password}{main},
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

    $method = 'get_account_status';
    $params = {token => $token};
    $c->call_ok($method, $params);
    $status = $c->result->{status};

    $test_client->status->_build_all;
    ok $test_client->status->allow_document_upload, 'allow_document_upload status set';
    is $test_client->status->reason('allow_document_upload'), 'MT5_ACCOUNT_IS_CREATED', 'allow_document_upload status set';

    $test_client->set_authentication('ID_DOCUMENT', {status => $ID_DOCUMENT});
    $test_client->save;
};

subtest 'new account dry_run using invalid arguments' => sub {
    my $method = 'mt5_new_account';

    # Invalid account type
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'an_invalid_account_type',
            country      => 'mt',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
            dry_run      => 1,
            company      => 'svg'
        },
    };
    $c->call_ok($method, $params)->has_error('invalid account_type on dry run')
        ->error_code_is('InvalidAccountType', 'invalid account_type entered on dry run')
        ->error_message_like(qr/We can't find this account/, 'error message for invalid account_type entered on dry run');

    # Invalid sub account type
    $params->{args}->{account_type}     = 'financial';
    $params->{args}->{mt5_account_type} = 'invalid_account_type';

    $c->call_ok($method, $params)->has_error('invalid mt5_account_type on dry run')
        ->error_code_is('InvalidSubAccountType', 'invalid mt5_account_type entered on dry run')
        ->error_message_like(qr/We can't find this account/, 'error message for invalid mt5_account_type entered on dry run');
};

subtest 'new account dry_run on a client with no account currency' => sub {
    my $test_client_with_no_currency = create_client('CR');
    my $method                       = 'mt5_new_account';
    my $params                       = {
        language => 'EN',
        token    => $m->create_token($test_client_with_no_currency->loginid, 'test token'),
        args     => {
            account_type => 'gaming',
            country      => 'mt',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
            dry_run      => 1,
            company      => 'svg'
        },
    };

    $c->call_ok($method, $params)->has_error('no currency set for the account')
        ->error_code_is('SetExistingAccountCurrency', 'provided client has no default currency on dry run')
        ->error_message_like(qr/Please set your account currency./, 'error message for client with no default currency on dry run');
};

subtest 'new account with switching' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        # Pass this virtual account token to test switching functionality.
        #   If the user has multiple client accounts the Binary.com front-end
        #   will pass to this function whichever one is currently selected.
        #   In this case we can automatically detect that the user has
        #   another account which qualifies them to open MT5 and switch.
        args => {
            account_type   => 'gaming',
            country        => 'mt',
            email          => $details{email},
            name           => $details{name},
            investPassword => 'Abcd1234',
            mainPassword   => $details{password}{main},
            leverage       => 100,
            company        => 'svg'
        },
    };
    # Expect error because we opened an account in the previous test.
    $c->call_ok($method, $params)->has_error('error from duplicate mt5_new_account')
        ->error_code_is('MT5CreateUserError', 'error code for duplicate mt5_new_account')
        ->error_message_like(qr/account already exists/, 'error message for duplicate mt5_new_account');
};

subtest 'MF should be allowed' => sub {

    my $mf_client = create_client('MF');
    $mf_client->set_default_account('EUR');
    $mf_client->$_($basic_details{$_}) for keys %basic_details;
    $mf_client->save();

    $user->add_client($mf_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'financial',
            country          => 'es',
            email            => $details{email},
            name             => $details{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $details{password}{main},
            company          => 'svg'
        },
    };

    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account for financial with no tax information');

    $test_client->tax_residence('mt');
    $test_client->tax_identification_number('111222333');
    $test_client->save;
};

subtest 'MF to MLT account switching' => sub {
    my $mf_switch_client = create_client('MF');
    $mf_switch_client->set_default_account('EUR');
    $mf_switch_client->residence('at');
    $mf_switch_client->account_opening_reason('speculative');

    my $mlt_switch_client = create_client('MLT');
    $mlt_switch_client->set_default_account('EUR');
    $mlt_switch_client->residence('at');
    $mlt_switch_client->account_opening_reason('speculative');

    $mf_switch_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data_mf)});
    $mf_switch_client->$_($basic_details{$_}) for keys %basic_details;

    $mf_switch_client->save();
    $mlt_switch_client->save();

    my $switch_user = BOM::User->create(
        email    => 'switch@binary.com',
        password => 's3kr1t',
    );
    $switch_user->update_trading_password($details{password}{main});
    $switch_user->add_client($mf_switch_client);

    my $mf_switch_token = $m->create_token($mf_switch_client->loginid, 'test token');

    # we should get an error if we are trying to open a gaming account

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $mf_switch_token,
        args     => {
            account_type   => 'gaming',
            country        => 'es',
            email          => $details{email},
            name           => $details{name},
            investPassword => 'Abcd1234',
            mainPassword   => $details{password}{main},
            company        => 'maltainvest'
        },
    };

    $c->call_ok($method, $params)->has_error('cannot create gaming account for MF only users')
        ->error_code_is('MT5NotAllowed', 'error should be account not available');

    # add MLT client
    $switch_user->add_client($mlt_switch_client);

    $c->call_ok($method, $params)->has_error('cannot create gaming account for MLT user')
        ->error_code_is('MT5NotAllowed', 'error should be account not available');

    # MF client should be allowed to open financial account as well
    $params->{args}->{account_type}     = 'financial';
    $params->{args}->{mt5_account_type} = 'financial';

    $params->{args}->{company} = 'maltainvest';
    $c->call_ok($method, $params)->has_no_error('financial account should be created');
    is($c->result->{account_type}, 'financial', 'account type should be financial');
};

subtest 'MLT to MF account switching' => sub {
    my $mf_switch_client = create_client('MF');
    $mf_switch_client->set_default_account('EUR');
    $mf_switch_client->residence('at');
    $mf_switch_client->tax_residence('at');
    $mf_switch_client->tax_identification_number('1234');
    $mf_switch_client->account_opening_reason('speculative');
    $mf_switch_client->phone('99121212');

    my $mlt_switch_client = create_client('MLT');
    $mlt_switch_client->set_default_account('EUR');
    $mlt_switch_client->residence('at');

    $mf_switch_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data_mf)});
    $mlt_switch_client->$_($basic_details{$_}) for keys %basic_details;

    $mf_switch_client->save();
    $mlt_switch_client->save();

    my $switch_user = BOM::User->create(
        email    => 'switch2@binary.com',
        password => 's3kr1t',
    );

    $switch_user->add_client($mlt_switch_client);
    $switch_user->update_trading_password($details{password}{main});
    my $mlt_switch_token = $m->create_token($mlt_switch_client->loginid, 'test token');

    # we should get an error if we are trying to open a financial account

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $mlt_switch_token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'financial',
            country          => 'es',
            email            => $details{email},
            name             => $details{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $details{password}{main},
            company          => 'maltainvest'
        },
    };

    $c->call_ok($method, $params)->has_error('cannot create financial account for MLT only users')
        ->error_code_is('FinancialAccountMissing', 'error should be financial account missing');

    # add MF client
    $switch_user->add_client($mf_switch_client);

    $c->call_ok($method, $params)->has_no_error('financial account should be created');
    is($c->result->{account_type}, 'financial', 'account type should be financial');

    # MLT client should be allowed to open gaming account as well
    $params->{args}->{account_type}     = 'gaming';
    $params->{args}->{mt5_account_type} = undef;

    $c->call_ok($method, $params)->has_error('cannot create gaming account for MLT user')
        ->error_code_is('MT5NotAllowed', 'error should be account not available');
};

subtest 'VRTC to MLT and MF account switching' => sub {
    my $mf_switch_client = create_client('MF');
    $mf_switch_client->set_default_account('GBP');
    $mf_switch_client->residence('at');
    $mf_switch_client->tax_residence('at');
    $mf_switch_client->tax_identification_number('1234');
    $mf_switch_client->account_opening_reason('speculative');

    my $mlt_switch_client = create_client('MLT');
    $mlt_switch_client->set_default_account('EUR');
    $mlt_switch_client->residence('at');

    my $vr_switch_client = create_client('VRTC');
    $vr_switch_client->set_default_account('USD');
    $vr_switch_client->residence('at');

    $mf_switch_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data_mf)});
    $mlt_switch_client->$_($basic_details{$_}) for keys %basic_details;

    $mf_switch_client->save();
    $mlt_switch_client->save();
    $vr_switch_client->save();

    my $switch_user = BOM::User->create(
        email    => 'switch+vrtc@binary.com',
        password => 's3kr1t',
    );

    $switch_user->add_client($vr_switch_client);
    $switch_user->update_trading_password($details{password}{main});

    my $vr_switch_token = $m->create_token($vr_switch_client->loginid, 'test token');

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $vr_switch_token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'financial',
            country          => 'es',
            email            => $details{email},
            name             => $details{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $details{password}{main},
            company          => 'maltainvest'
        },
    };

    $c->call_ok($method, $params)->has_error("Only real accounts are allowed to open real accounts")
        ->error_code_is("AccountShouldBeReal", "error should be 'cannot open real account'");

    # Add dry_run test, we should get exact result like previous test
    $params->{args}->{dry_run} = 1;
    $c->call_ok($method, $params)->has_error("Only real accounts are allowed to open real accounts")
        ->error_code_is("AccountShouldBeReal", "error should be 'cannot open real account'");

    # Reset params after dry_run test
    $params->{args}->{dry_run} = 0;
};

subtest 'CR to MLT and MF account switching' => sub {
    my $mf_switch_client = create_client('MF');
    $mf_switch_client->set_default_account('GBP');
    $mf_switch_client->residence('at');
    $mf_switch_client->tax_residence('at');
    $mf_switch_client->tax_identification_number('1234');
    $mf_switch_client->account_opening_reason('speculative');

    my $mlt_switch_client = create_client('MLT');
    $mlt_switch_client->set_default_account('EUR');
    $mlt_switch_client->residence('at');

    my $cr_switch_client = create_client('CR');
    $cr_switch_client->set_default_account('USD');
    $cr_switch_client->residence('at');

    $mf_switch_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data_mf)});
    $mlt_switch_client->$_($basic_details{$_}) for keys %basic_details;

    $mf_switch_client->save();
    $mlt_switch_client->save();
    $cr_switch_client->save();

    my $switch_user = BOM::User->create(
        email    => 'switch+cr@binary.com',
        password => 's3kr1t',
    );

    $switch_user->add_client($cr_switch_client);
    $switch_user->update_trading_password($details{password}{main});

    my $cr_switch_token = $m->create_token($cr_switch_client->loginid, 'test token');

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $cr_switch_token,
        args     => {
            account_type   => 'gaming',
            country        => 'es',
            email          => $details{email},
            name           => $details{name},
            investPassword => 'Abcd1234',
            mainPassword   => $details{password}{main},
            company        => 'maltainvest'
        },
    };

    $switch_user->add_client($mlt_switch_client);

    $c->call_ok($method, $params)->has_error('cannot create gaming account for MLT user')
        ->error_code_is('MT5NotAllowed', 'error should be account not available');

    # we should get an error if we are trying to open a financial account

    $method = 'mt5_new_account';
    $params = {
        language => 'EN',
        token    => $cr_switch_token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'financial',
            country          => 'es',
            email            => $details{email},
            name             => $details{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $details{password}{main},
            company          => 'maltainvest'
        },
    };

    $c->call_ok($method, $params)->has_error('cannot create financial account for MLT only users')
        ->error_code_is('FinancialAccountMissing', 'error should be permission denied');

    # add MF client
    $switch_user->add_client($mf_switch_client);

    $c->call_ok($method, $params)->has_no_error('financial account should be created');
    is($c->result->{account_type}, 'financial', 'account type should be financial');
};

subtest 'new account on addtional trade server' => sub {
    my $mocked = Test::MockModule->new('BOM::Config');
    $mocked->mock(
        'mt5_server_routing',
        sub {
            return {
                real => {},
                demo => {}};
        });
    my $new_email  = 'abc' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'za'});
    my $token      = $m->create_token($new_client->loginid, 'test token');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
            company      => 'svg'
        },
    };
    note("creates a gaming account with old server config");
    $c->call_ok($method, $params)->has_no_error('mt5 new account with old config za goes real\p01_ts01');
    is($c->result->{balance},         0,                                                           'Balance is 0');
    is($c->result->{display_balance}, '0.00',                                                      'Display balance is "0.00"');
    is($c->result->{currency},        'USD',                                                       'Currency is "USD"');
    is($c->result->{login},           'MTR' . $accounts{'real\p01_ts01\synthetic\svg_std_usd\01'}, 'login is MTR00001013');

    note('suspend mt5 real\p01_ts02. Tries to create financial account with new config.');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(1);
    $mocked->unmock_all;
    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial';
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(0);

    note('unsuspend mt5 real\p01_ts02. Tries to create financial account with new config.');
    $params->{args}{mt5_account_category} = 'conventional';
    $c->call_ok($method, $params)->has_no_error('mt5 new account with new config');
    is($c->result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\svg_std_usd'}, 'login is MTR1001016');
    $mocked->unmock_all;
};

subtest 'new account identical account check' => sub {
    my $mock_mt5_rpc = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mock_mt5_rpc->mock(
        get_mt5_logins => sub {
            return Future->done({
                login    => 'MTR100\p01_ts01',
                group    => 'real\svg',
                balance  => 1000,
                currency => 'USD',
            });
        });
    my $new_email  = 'abcd' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'za'});
    my $token      = $m->create_token($new_client->loginid, 'test token');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
            company      => 'svg'
        },
    };
    note("creates a gaming account with existing account with old group name on a different server is allowed");
    $c->call_ok($method, $params)->has_no_error('can create synthetic account on real\p01_ts02 when clean has identical account on real\p01_ts01');
};

subtest 'country=za; creates financial account with existing gaming account while real\p01_ts02 disabled' => sub {
    my $new_email  = 'abcdef' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'za'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
            company      => 'svg'
        },
    };
    my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'gaming',                                             'account_type=gaming';
    is $result->{login}, 'MTR' . $accounts{'real\p01_ts02\synthetic\svg_std_usd\01'}, 'created in group real\p01_ts02\synthetic\svg_std_usd\01';

    note("disable real->p01_ts02 API calls.");
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(1);

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial';
    my $financial = $c->call_ok($method, $params)->has_no_error->result;
    is $financial->{account_type}, 'financial',                                              'account_type=financial';
    is $financial->{login},        'MTR' . $accounts{'real\p01_ts01\financial\svg_std_usd'}, 'created in group real\p01_ts01\financial\svg_std_usd';
};

subtest 'country=au, financial account' => sub {
    my $new_email  = 'au' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'au'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('AUD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'financial',
            email            => $new_email,
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 100,
            company          => 'svg'
        },
    };
    my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'financial',                                           'account_type=financial';
    is $result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\svg_std-lim_usd'}, 'created in group real\p01_ts01\financial\svg_std-lim_usd';

    $params->{args}->{account_type} = 'demo';
    $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'demo',                                                'account_type=demo';
    is $result->{login}, 'MTD' . $accounts{'demo\p01_ts01\financial\svg_std-lim_usd'}, 'created in group demo\p01_ts01\financial\svg_std-lim_usd';

    $params->{args}->{account_type}     = 'financial';
    $params->{args}->{mt5_account_type} = 'financial_stp';
    $params->{args}->{company}          = 'labuan';
    $result                             = $c->call_ok($method, $params)->has_error->error_code_is('MT5NotAllowed')
        ->error_message_is('MT5 financial account is not available in your country yet.');

    $params->{args}->{mt5_account_type} = 'financial';
    $params->{args}->{company}          = 'svg';
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_svg_financial(0);
    # same account 'real\p01_ts01\financial\svg_std-lim_usd' is already created
    $result =
        $c->call_ok($method, $params)->has_error->error_code_is('MT5CreateUserError')
        ->error_message_is(
        'An account already exists with the information you provided. If you\'ve forgotten your username or password, please contact us.');
};

subtest 'country=latam african, financial STP account' => sub {

    #qw(dz ao ai ag ar aw bs bb bz bj bo bw bv br io bf bi cv cm ky cf td cl co km cg cd cr ci cu cw dj dm do ec eg sv gq er sz et fk gf tf ga gm gh gd gp gt gn gw gy ht hn jm ke ls lr ly mg mw ml mq mr mu yt mx ms ma mz na ni ne ng pa pe re bl sh kn lc mf vc st sn sc sl sx so za gs sd sr tz tg tt tn tc ug uy ve eh zm zw ss);
    my @latam_african_countries =
        qw(dz ao ai ag ar bs bz bj bo bw br bi cv cm cf td cl co km cg cr ci dj dm do ec eg sv gq er sz et ga gm gh gd gt gn gw gy hn ke ls lr mg mw mu mx ms mz na ne ng pa pe kn lc vc st sc sl so za sd sr tz tg tt tn tc uy ve zm zw);

    my @high_risk_countries      = ('jo', 'ru');
    my @onfido_blocked_countries = ('cn', 'ru', 'by');
    foreach my $country (@latam_african_countries) {
        my $new_email  = $country . $details{email};
        my $new_client = create_client('CR', undef, {residence => $country});
        my $token      = $m->create_token($new_client->loginid, 'test token 2');
        $new_client->set_default_account('USD');
        $new_client->email($new_email);

        my $user = BOM::User->create(
            email    => $new_email,
            password => 's3kr1t',
        );
        $user->update_trading_password($details{password}{main});
        $user->add_client($new_client);

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type     => 'financial',
                mt5_account_type => 'financial_stp',
                email            => $new_email,
                name             => $details{name},
                mainPassword     => $details{password}{main},
                leverage         => 100,
                company          => 'labuan'
            },
        };

        # Fill up required user details for financial_stp account
        $new_client->status->clear_crs_tin_information;
        $new_client->phone('12345678');
        $new_client->tax_residence('mt');
        $new_client->tax_identification_number('111222333');
        $new_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $new_client->account_opening_reason('nothing');
        $new_client->save;

        if (grep { $country eq $_ } @high_risk_countries, @onfido_blocked_countries) {
            $c->call_ok($method, $params)->has_error->error_code_is('MT5NotAllowed');
        } else {
            my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
            is $result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\labuan_stp_usd'};
        }

    }
};

# reset
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02($p01_ts02_load);
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03($p01_ts03_load);

subtest 'allow creating bvi/vanuatu account if poi status is not verified' => sub {

    my $new_email  = 'br_poi_not_verified_' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'br'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);
    $new_client->tax_identification_number('1234');
    $new_client->tax_residence('br');
    $new_client->place_of_birth('br');
    $new_client->account_opening_reason('speculative');

    my $user = BOM::User->create(
        email    => $new_email,
        password => 'restrictMeToBVI',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);
    #$new_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $new_client->save;

    my $user_client_mock = Test::MockModule->new('BOM::User');
    $user_client_mock->mock(
        'update_loginid_status',
        sub {
            return 1;
        });

    my $method        = 'mt5_new_account';
    my $client_params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'br',
            email            => $new_email,
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 1000,
            mt5_account_type => 'financial',
            company          => 'bvi'
        },
    };

    # not verified
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_svg_financial(0);
    $c->call_ok($method, $client_params);

    $client_params->{args}->{company} = 'vanuatu';
    $c->call_ok($method, $client_params);
    #my $result = $c->call_ok($method, $client_params)->has_no_error->result;
    #is $result->{account_type}, 'financial', 'account_type=financial';
    #is $result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\bvi_std_usd'}, 'created in group real\p01_ts01\financial\bvi_std_usd';
};

subtest 'bvi/vanuatu if poi status is verified, poa failed' => sub {

    my $new_email  = 'br_poi_verified_poa_failed' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'br'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);
    $new_client->tax_identification_number('1234');
    $new_client->tax_residence('br');
    $new_client->account_opening_reason('speculative');
    $new_client->place_of_birth('br');

    my $user = BOM::User->create(
        email    => $new_email,
        password => 'red1rectMeToBVI',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);
    $new_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $new_client->save;

    my $method        = 'mt5_new_account';
    my $client_params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'br',
            email            => $new_email,
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 1000,
            mt5_account_type => 'financial',
            company          => 'bvi'
        },
    };

    #don't A book the account
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_bvi_financial(0);

    my $doc_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    $doc_mock->mock(
        'expired',
        sub {
            return 1;
        });
    #verified in brasil and standard risk
    $c->call_ok($method, $client_params)->has_error->error_code_is('ExpiredDocumentsMT5');

    $client_params->{args}->{company} = 'vanuatu';
    $c->call_ok($method, $client_params)->has_error->error_code_is('ExpiredDocumentsMT5');

};

subtest 'bvi/vanuatu if poi status is verified, get_poa_status -> none' => sub {

    my $new_email  = 'br_poi_verified_get_poa_status_none' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'br'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);
    $new_client->tax_identification_number('1234');
    $new_client->tax_residence('br');
    $new_client->account_opening_reason('speculative');
    $new_client->place_of_birth('br');

    my $user = BOM::User->create(
        email    => $new_email,
        password => 'red1rectMeToBVI',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);
    $new_client->save;

    my $method        = 'mt5_new_account';
    my $client_params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'br',
            email            => $new_email,
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 1000,
            mt5_account_type => 'financial',
            company          => 'bvi'
        },
    };

    #don't A book the account
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_bvi_financial(0);

    my $user_client_mock = Test::MockModule->new('BOM::User::Client');
    $user_client_mock->mock(
        'get_poi_status',
        sub {
            return 'verified';
        });
    $user_client_mock->mock(
        'get_poa_status',
        sub {
            return 'none';
        });
    #verified in brasil and standard risk
    $c->call_ok($method, $client_params);

    $client_params->{args}->{company} = 'vanuatu';
    $c->call_ok($method, $client_params);

};

subtest 'bvi/vanuatu if poi status is verified, get_poa_status -> pending' => sub {

    my $new_email  = 'br_poi_verified_get_poa_status_pending' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'br'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);
    $new_client->tax_identification_number('1234');
    $new_client->tax_residence('br');
    $new_client->account_opening_reason('speculative');
    $new_client->place_of_birth('br');

    my $user = BOM::User->create(
        email    => $new_email,
        password => 'red1rectMeToBVI',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);
    $new_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $new_client->save;

    my $method        = 'mt5_new_account';
    my $client_params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'br',
            email            => $new_email,
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 1000,
            mt5_account_type => 'financial',
            company          => 'bvi'
        },
    };

    #don't A book the account
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_bvi_financial(0);

    my $user_client_mock = Test::MockModule->new('BOM::User::Client');
    $user_client_mock->mock(
        'get_poa_status',
        sub {
            return 'pending';
        });

    my $user_mock = Test::MockModule->new('BOM::User');
    $user_mock->mock(
        'update_loginid_status',
        sub {
            return 1;
        });

    my $result = $c->call_ok($method, $client_params)->has_no_error('account (bvi) created successfully with poa as pending')->result;
    is $result->{account_type}, 'financial',                                              'account type is financial';
    is $result->{login},        'MTR' . $accounts{'real\p01_ts01\financial\bvi_std_usd'}, 'created in group real\p01_ts01\financial\bvi_std_usd';

    $client_params->{args}->{company} = 'vanuatu';
    $result = $c->call_ok($method, $client_params)->has_no_error('account (vanuatu) created successfully with poa as pending')->result;
    is $result->{account_type}, 'financial', 'account type is financial';
    is $result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\vanuatu_std-hr_usd'},
        'created in group real\p01_ts01\financial\vanuatu_std-hr_usd';

};

subtest 'bvi/vanuatu if poi status is verified, get_poa_status -> rejected' => sub {

    my $new_email  = 'br_poi_verified_get_poa_status_rejected' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'br'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);
    $new_client->tax_identification_number('1234');
    $new_client->tax_residence('br');
    $new_client->account_opening_reason('speculative');
    $new_client->place_of_birth('br');

    my $user = BOM::User->create(
        email    => $new_email,
        password => 'red1rectMeToBVI',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);
    $new_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $new_client->save;

    my $method        = 'mt5_new_account';
    my $client_params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'br',
            email            => $new_email,
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 1000,
            mt5_account_type => 'financial',
            company          => 'bvi'
        },
    };

    #don't A book the account
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_bvi_financial(0);

    my $user_client_mock = Test::MockModule->new('BOM::User::Client');
    $user_client_mock->mock(
        'get_poa_status',
        sub {
            return 'rejected';
        });

    my $user_mock = Test::MockModule->new('BOM::User');
    $user_mock->mock(
        'update_loginid_status',
        sub {
            return 1;
        });

    my $result = $c->call_ok($method, $client_params)->has_no_error('account (bvi) created successfully with poa as pending')->result;
    is $result->{account_type}, 'financial',                                              'account type is financial';
    is $result->{login},        'MTR' . $accounts{'real\p01_ts01\financial\bvi_std_usd'}, 'created in group real\p01_ts01\financial\bvi_std_usd';

    $client_params->{args}->{company} = 'vanuatu';
    $result = $c->call_ok($method, $client_params)->has_no_error('account (vanuatu) created successfully with poa as pending')->result;
    is $result->{account_type}, 'financial', 'account type is financial';
    is $result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\vanuatu_std-hr_usd'},
        'created in group real\p01_ts01\financial\vanuatu_std-hr_usd';

};

subtest 'bvi/vanuatu if poi status is verified, get_poa_status -> expired' => sub {

    my $new_email  = 'br_poi_verified_get_poa_status_expired' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'br'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);
    $new_client->tax_identification_number('1234');
    $new_client->tax_residence('br');
    $new_client->account_opening_reason('speculative');
    $new_client->place_of_birth('br');

    my $user = BOM::User->create(
        email    => $new_email,
        password => 'red1rectMeToBVI',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);
    $new_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $new_client->save;

    my $method        = 'mt5_new_account';
    my $client_params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'br',
            email            => $new_email,
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 1000,
            mt5_account_type => 'financial',
            company          => 'bvi'
        },
    };

    #don't A book the account
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_bvi_financial(0);

    my $user_client_mock = Test::MockModule->new('BOM::User::Client');
    $user_client_mock->mock(
        'get_poa_status',
        sub {
            return 'expired';
        });

    my $user_mock = Test::MockModule->new('BOM::User');
    $user_mock->mock(
        'update_loginid_status',
        sub {
            return 1;
        });

    my $result = $c->call_ok($method, $client_params)->has_no_error('account (bvi) created successfully with poa as pending')->result;
    is $result->{account_type}, 'financial',                                              'account type is financial';
    is $result->{login},        'MTR' . $accounts{'real\p01_ts01\financial\bvi_std_usd'}, 'created in group real\p01_ts01\financial\bvi_std_usd';

    $client_params->{args}->{company} = 'vanuatu';
    $result = $c->call_ok($method, $client_params)->has_no_error('account (vanuatu) created successfully with poa as pending')->result;
    is $result->{account_type}, 'financial', 'account type is financial';
    is $result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\vanuatu_std-hr_usd'},
        'created in group real\p01_ts01\financial\vanuatu_std-hr_usd';

};

subtest 'bvi/vanuatu fully authenticated' => sub {

    my $new_email  = 'br_poi_failed_poa_verified_' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'br'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);
    $new_client->tax_identification_number('1234');
    $new_client->tax_residence('br');
    $new_client->account_opening_reason('speculative');
    $new_client->place_of_birth('Wakanda');

    my $user = BOM::User->create(
        email    => $new_email,
        password => 'red1rectMeToBVI',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);
    $new_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $new_client->save;

    my $method        = 'mt5_new_account';
    my $client_params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'br',
            email            => $new_email,
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 1000,
            mt5_account_type => 'financial',
            company          => 'bvi'
        },
    };

    # A book the account
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_bvi_financial(1);

    #verified in brasil and high risk
    my $result = $c->call_ok($method, $client_params)->has_no_error('financial account successfully created BVI A book')->result;
    is $result->{account_type}, 'financial',                                          'account_type is financial';
    is $result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\bvi_std-hr_usd'}, 'created in group real\p01_ts01\financial\bvi_std-hr_usd';

    $client_params->{args}->{company} = 'vanuatu';
    $result = $c->call_ok($method, $client_params)->has_no_error('financial account successfully created Vanuatu')->result;
    is $result->{account_type}, 'financial', 'account_type is financial';
    is $result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\vanuatu_std-hr_usd'},
        'created in group real\p01_ts01\financial\vanuatu_std-hr_usd';

    $client_params->{args}->{account_type}     = 'gaming';
    $client_params->{args}->{mt5_account_type} = '';
    $client_params->{args}->{company}          = 'bvi';
    $result = $c->call_ok($method, $client_params)->has_no_error('gaming account successfully created BVI')->result;
    is $result->{account_type}, 'gaming',                                                 'account_type is gaming';
    is $result->{login},        'MTR' . $accounts{'real\p01_ts04\synthetic\bvi_std_usd'}, 'created in group real\p01_ts01\synthetic\bvi_std_usd';

};

subtest 'countries restrictions, high-risk jurisdiction, onfido blocked' => sub {
    my @countries = qw(cn ru);

    # do not create vg for bvi
    # bb and ru is in high risk
    # aq and bv is onfido blocked
    foreach my $country (@countries) {
        my $new_email  = 'restriction_tests_' . $country . $details{email};
        my $new_client = create_client('CR', undef, {residence => $country});
        my $token      = $m->create_token($new_client->loginid, 'test token 2');
        $new_client->set_default_account('USD');
        $new_client->email($new_email);
        $new_client->tax_identification_number('1234');
        $new_client->tax_residence($country);
        $new_client->account_opening_reason('speculative');

        my $user = BOM::User->create(
            email    => $new_email,
            password => 'red1rectMeToBVI',
        );
        $user->update_trading_password($details{password}{main});
        $user->add_client($new_client);
        $new_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $new_client->save;

        my $method        = 'mt5_new_account';
        my $client_params = {
            token => $token,
            args  => {
                account_type     => 'financial',
                email            => $new_email,
                name             => $details{name},
                mainPassword     => $details{password}{main},
                leverage         => 1000,
                mt5_account_type => 'financial',
                company          => 'bvi'
            },
        };

        $c->call_ok($method, $client_params)->has_error->error_code_is('MT5NotAllowed');
    }

};

subtest 'country=id, mt5 swap free account' => sub {
    my $new_email  = 'id' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'id'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type         => 'all',
            email                => $new_email,
            name                 => $details{name},
            mainPassword         => $details{password}{main},
            leverage             => 100,
            company              => 'svg',
            sub_account_category => 'swap_free'
        },
    };
    my $result = $c->call_ok($method, $params)->has_no_error('real swap free account successfully created')->result;
    $params->{args}->{account_type} = 'demo';
    $result = $c->call_ok($method, $params)->has_no_error('demo swap free account successfully created')->result;
};

subtest 'VRTC client cannot create real MT5 account' => sub {
    my $method = 'mt5_new_account';

    # Financial account
    my $client_params = {
        token => $token_vr,
        args  => {
            account_type     => 'financial',
            email            => $details{email},
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 1000,
            mt5_account_type => 'financial',
            company          => 'bvi'
        },
    };

    $c->call_ok($method, $client_params)->has_error->error_code_is('AccountShouldBeReal');

    # Gaming account
    $client_params = {
        token => $token_vr,
        args  => {
            account_type => 'gaming',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 1000,
            company      => 'bvi'
        },
    };

    $c->call_ok($method, $client_params)->has_error->error_code_is('AccountShouldBeReal');
};

done_testing();
