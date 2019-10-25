use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warnings qw(warning);
use BOM::Test::RPC::Client;

use MojoX::JSON::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;
use BOM::User::Password;
use BOM::Platform::Token;
use BOM::User;
use BOM::User::Client;
use BOM::User::Password;
use Email::Stuffer::TestLinks;

my ($t, $rpc_ct);
my $client_mocked      = Test::MockModule->new('BOM::User::Client');
my $status_mocked      = Test::MockModule->new('BOM::User::Client::Status');
my @can_affect_cashier = (
    'age_verification',        'crs_tin_information',   'cashier_locked',             'disabled',
    'financial_risk_approval', 'ukgc_funds_protection', 'max_turnover_limit_not_set', 'unwelcome',
    'withdrawal_locked'
);
my %seen;

foreach my $status (@can_affect_cashier) {
    $status_mocked->mock(
        $status,
        sub {
            $seen{$status} = 1;
            return $status_mocked->original($status)->(@_);
        });
}

my $runtime_system = BOM::Config::Runtime->instance->app_config->system;

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

my $params = {
    language => 'EN',
    source   => 1,
    args     => {},
};

my $current_tnc_version = BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_version;
my $email               = 'dummy' . rand(999) . '@binary.com';

my $user_client_vr = BOM::User->create(
    email          => 'vr@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email
});
$user_client_vr->add_client($client_vr);

my $user_client_cr = BOM::User->create(
    email          => 'cr@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    first_name     => 'John',
    phone          => '6060842',
    place_of_birth => 'id',
});
$user_client_cr->add_client($client_cr);

my $user_client_cr1 = BOM::User->create(
    email          => 'cr1@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email
});
$user_client_cr1->add_client($client_cr1);

my $user_client_mf = BOM::User->create(
    email          => 'mf@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    email       => $email
});
$user_client_mf->add_client($client_mf);

my $user_client_mlt = BOM::User->create(
    email          => 'mlt@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    email       => $email,
    first_name  => 'John',
    phone       => '6060842'
});
$user_client_mlt->add_client($client_mlt);

my $user_client_mx = BOM::User->create(
    email          => 'mx@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    email       => $email
});
$user_client_mx->add_client($client_mx);
$client_mx->status->set('max_turnover_limit_not_set', 'tests', 'Newly created GB clients have this status until they set 30Day turnover');

my $method = 'cashier';
subtest 'common' => sub {
    $params->{args}->{cashier} = 'deposit';
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Cashier forward error as client is virtual')
        ->error_message_is('This is a virtual-money account. Please switch to a real-money account to access cashier.',
        'Correct error message for virtual account');

    my $user_mocked = Test::MockModule->new('BOM::User');
    $user_mocked->mock('new', sub { bless {}, 'BOM::User' });

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mx->loginid, 'test token');
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('ASK_TNC_APPROVAL', 'Client needs to approve tnc before')
        ->error_message_is('Terms and conditions approval is required.', 'Correct error message for terms and conditions');

    $client_mf->status->set('tnc_approval', 'system', $current_tnc_version);

    $client_mx->status->set('tnc_approval', 'system', $current_tnc_version);

    $client_cr1->status->set('tnc_approval', 'system', $current_tnc_version);
    $client_cr1->set_default_account('JPY');
    $client_cr1->save;

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has wrong default currency for landing_company')
        ->error_message_is('JPY transactions may not be performed with this account.', 'Correct error message for wrong default account');

    $client_cr->status->set('tnc_approval', 'system', $current_tnc_version);

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token');
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('ASK_CURRENCY', 'Client has no default currency')
        ->error_message_is('Please set the currency.', 'Correct error message when currency is not set');

    $client_cr->set_default_account('USD');
    $client_cr->save;

    $client_mocked->mock('documents_expired', sub { return 1 });

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client documents have expired')
        ->error_message_is(
        'Your identity documents have passed their expiration date. Kindly send a scan of a valid identity document to support@binary.com to unlock your cashier.',
        'Correct error message for documents expired'
        );

    $client_mocked->unmock('documents_expired');
    $client_cr->status->set('cashier_locked', 'system');

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has cashier lock')
        ->error_message_is('Your cashier is locked.', 'Correct error message for locked cashier');

    $client_cr->status->clear_cashier_locked;
    $client_cr->status->set('disabled', 'system');

    # as we check if client is disabled during token verification so it will not go to cashier
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('DisabledClient', 'Client is disabled')
        ->error_message_is('This account is unavailable.', 'Correct error message for disabled client');

    $client_cr->status->clear_disabled;
    $client_cr->save;
};

subtest 'deposit' => sub {
    $runtime_system->suspend->cashier(1);
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Cashier is suspended')
        ->error_message_is('Sorry, cashier is temporarily unavailable due to system maintenance.',
        'Correct error message for withdrawal when cashier is locked.');
    $runtime_system->suspend->cashier(0);

    $client_cr->status->set('unwelcome', 'system');

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client marked as unwelcome')
        ->error_message_is('Your account is restricted to withdrawals only.', 'Correct error message for client marked as unwelcome');

    $client_cr->status->clear_unwelcome;

    $runtime_system->suspend->cashier(1);
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Cashier is suspended')
        ->error_message_is('Sorry, cashier is temporarily unavailable due to system maintenance.',
        'Correct error message for deposit when cashier is locked.');
    $runtime_system->suspend->cashier(0);
};

subtest 'withdraw' => sub {
    $params->{args}->{cashier} = 'withdraw';

    $client_cr->status->set('withdrawal_locked', 'system', 'locked for security reason');

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('ASK_EMAIL_VERIFY', 'Withdrawal needs verification token')
        ->error_message_is('Verify your withdraw request.', 'Withdrawal needs verification token');

    $client_mx->status->set('tnc_approval', 'system', 'some dummy value');

    $params->{args}->{verification_code} = BOM::Platform::Token->new({
            email       => $client_mx->email,
            expires_in  => 3600,
            created_for => 'payment_withdraw',
        })->token;

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mx->loginid, 'test token1');
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_CURRENCY',
        'Terms and condition check is skipped for withdrawal, currency check comes after that.')
        ->error_message_is('Please set the currency.', 'Correct error message as terms and condition check is skipped for withdrawal.');

    $client_mx->status->set('tnc_approval', 'system', $current_tnc_version);

    $params->{args}->{verification_code} = BOM::Platform::Token->new({
            email       => $client_mx->email,
            expires_in  => 3600,
            created_for => 'payment_withdraw',
        })->token;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_CURRENCY',
        'Terms and condition check is skipped for withdrawal, even with correct version set same currency error occur.')
        ->error_message_is('Please set the currency.', 'Correct error message as terms and condition check is skipped for withdrawal.');

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token1');
    $params->{args}->{verification_code} = BOM::Platform::Token->new({
            email       => $client_cr->email,
            expires_in  => 3600,
            created_for => 'payment_withdraw',
        })->token;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has withdrawal lock')
        ->error_message_is('Your account is locked for withdrawals.', 'Client is withdrawal locked');

    $client_cr->status->clear_withdrawal_locked;
};

subtest 'landing_companies_specific' => sub {
    $params->{args}->{cashier} = 'deposit';
    delete $params->{args}->{verification_code};

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mlt->loginid, 'test token1');

    $client_mlt->set_default_account('EUR');
    $client_mlt->status->set('tnc_approval', 'system', $current_tnc_version);
    $client_mlt->save;

    $client_mlt->aml_risk_classification('high');
    $client_mlt->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('FinancialAssessmentRequired',
        'MLT client with High risk should have completed financial assessment')
        ->error_message_is('Please complete the financial assessment form to lift your withdrawal and trading limits.',
        'MLT client with High risk should have completed financial assessment');

    $client_mlt->aml_risk_classification('low');
    $client_mlt->save;

    warning {
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('CashierForwardError',
            'MLT client deposit request was forwarded to cashier after AML had been changed to low')
            ->error_message_is('Sorry, an error occurred. Please try accessing our cashier again.',
            'Attempted to forward request to the cashier after validation');
    };

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mf->loginid, 'test token1');

    $client_mf->set_default_account('EUR');
    $client_mf->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('FinancialAssessmentRequired',
        'MF client has to complete financial assessment irrespective of risk classification')->error_message_is(
        'Please complete the financial assessment form to lift your withdrawal and trading limits.',
        'MF client has to complete financial assessment irrespective of risk classification'
        );

    $client_mf->financial_assessment({data => BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa()});
    $client_mf->save();

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_AUTHENTICATE', 'MF client needs to be fully authenticated')
        ->error_message_is('Please authenticate your account.', 'MF client needs to be fully authenticated');

    $client_mf->set_authentication('ID_DOCUMENT')->status('pass');
    $client_mf->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_FINANCIAL_RISK_APPROVAL', 'financial risk approval is required')
        ->error_message_is('Financial Risk approval is required.', 'financial risk approval is required');

    $client_mf->status->set('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_TIN_INFORMATION', 'tax information is required for malatainvest')
        ->error_message_is('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.',
        'tax information is required for malatainvest');

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mx->loginid, 'test token2');

    $client_mx->set_default_account('GBP');
    $client_mx->residence('gb');
    $client_mx->save;

    $client_mx->aml_risk_classification('high');
    $client_mx->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('FinancialAssessmentRequired',
        'MX client have to complete financial assessment if they are categorized as high risk')->error_message_is(
        'Please complete the financial assessment form to lift your withdrawal and trading limits.',
        'MX client have to complete financial assessment if they are categorized as high risk'
        );

    $client_mx->aml_risk_classification('low');
    $client_mx->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_UK_FUNDS_PROTECTION', 'GB residence needs to accept fund protection')
        ->error_message_is('Please accept Funds Protection.', 'GB residence needs to accept fund protection');
    $client_mx->status->set('ukgc_funds_protection', 'system', 'testing');
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_SELF_EXCLUSION_MAX_TURNOVER_SET', 'GB residence needs to set 30-Day turnover')
        ->error_message_is('Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.',
        'GB residence needs to set 30-Day turnover');
};

subtest 'all status are covered' => sub {
    # Flags that can affect cashier should be seen
    my @can_affect_cashier = (
        'age_verification',        'crs_tin_information',   'cashier_locked',             'disabled',
        'financial_risk_approval', 'ukgc_funds_protection', 'max_turnover_limit_not_set', 'unwelcome',
        'withdrawal_locked'
    );
    fail("missing status $_") for sort grep !exists $seen{$_}, @can_affect_cashier;
    pass("ok to prevent warning 'no tests run");
    done_testing();
};

subtest 'crypto_cashier_forward_page' => sub {
    my $prefix       = 'cryptocurrency';
    my $language     = 'EN';
    my $currency     = "BTC";
    my $loginid      = 'CR90000000';
    my $website_name = '';
    my $brand_name   = 'binary.com';
    my $action       = 'deposit';
    my $app_id       = 1098;
    my $deriv_brand_name   = 'deriv.app';
    my $deriv_app_id       = 16303;

    my $invalid_deposit = BOM::RPC::v3::Cashier::_get_cashier_url(
        $prefix,
        {
            loginid      => $loginid,
            website_name => $website_name,
            currency     => $currency,
            action       => $action,
            language     => $language,
            brand_name   => $brand_name,
            app_id       => $app_id,
            domain       => 'binary.la',
        });

    ok $invalid_deposit =~ /^https:\/\/crypto-cashier.binary.com/, 'valid domain to invalid domain';
    my $valid_deposit = BOM::RPC::v3::Cashier::_get_cashier_url(
        $prefix,
        {
            loginid      => $loginid,
            website_name => $website_name,
            currency     => $currency,
            action       => $action,
            language     => $language,
            brand_name   => $brand_name,
            app_id       => $app_id,
            domain       => 'binary.me',
        });
    ok $valid_deposit =~ /^https:\/\/crypto-cashier.binary.me/, 'valid domain to valid domain';
    my $deriv_invalid_deposit = BOM::RPC::v3::Cashier::_get_cashier_url(
        $prefix,
        {
            loginid      => $loginid,
            website_name => $website_name,
            currency     => $currency,
            action       => $action,
            language     => $language,
            brand_name   => $deriv_brand_name,
            app_id       => $deriv_app_id,
            domain       => 'deriv.la',
        });

    ok $deriv_invalid_deposit =~ /^https:\/\/crypto-cashier.binary.com/, 'valid deriv domain to invalid domain';
    my $deriv_valid_deposit = BOM::RPC::v3::Cashier::_get_cashier_url(
        $prefix,
        {
            loginid      => $loginid,
            website_name => $website_name,
            currency     => $currency,
            action       => $action,
            language     => $language,
            brand_name   => $deriv_brand_name,
            app_id       => $deriv_app_id,
            domain       => 'deriv.app',
        });

    ok $deriv_valid_deposit =~ /^https:\/\/crypto-cashier.deriv.app/, 'valid deriv domain to valid deriv domain';

    $website_name = 'binaryqa25.com';
    my $valid_QA_deposit = BOM::RPC::v3::Cashier::_get_cashier_url(
        $prefix,
        {
            loginid      => $loginid,
            website_name => $website_name,
            currency     => $currency,
            action       => $action,
            language     => $language,
            brand_name   => $brand_name,
            app_id       => $app_id,
            domain       => 'binary.me',
        });
    ok $valid_QA_deposit =~ /^https:\/\/www.binaryqa25.com/;

};

done_testing();
