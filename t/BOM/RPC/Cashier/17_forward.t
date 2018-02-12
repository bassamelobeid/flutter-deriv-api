use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::FailWarnings;
use BOM::Test::RPC::Client;

use MojoX::JSON::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;
use BOM::Platform::Password;
use BOM::Platform::Token;
use BOM::Platform::User;
use Client::Account;

my ($t, $rpc_ct);
my $client_mocked = Test::MockModule->new('Client::Account');
my %seen;
$client_mocked->mock(
    'get_status',
    sub {
        my $status = $_[1];
        $seen{$status}++;
        return $client_mocked->original('get_status')->(@_);
    });

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

my $params = {
    language => 'EN',
    source   => 1,
    args     => {},
};

my $email     = 'dummy' . rand(999) . '@binary.com';
my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email
});
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email
});
my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email
});
my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    email       => $email
});
my $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    email       => $email
});
$client_mx->set_status('ukrts_max_turnover_limit_not_set', 'tests', 'Newly created GB clients have this status until they set 30Day turnover');
my $client_jp = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'JP',
    email       => $email
});

my $method = 'cashier';
subtest 'common' => sub {
    $params->{args}->{cashier} = 'deposit';
    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_vr->loginid, 'test token');

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Cashier forward error as client is virtual')
        ->error_message_is('This is a virtual-money account. Please switch to a real-money account to access cashier.',
        'Correct error message for virtual account');

    my $user_mocked = Test::MockModule->new('BOM::Platform::User');
    $user_mocked->mock('new', sub { bless {}, 'BOM::Platform::User' });

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr1->loginid, 'test token');
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('ASK_TNC_APPROVAL', 'Client needs to approve tnc before')
        ->error_message_is('Terms and conditions approval is required.', 'Correct error message for terms and conditions');

    my $current_tnc_version = BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version;

    $client_mf->set_status('tnc_approval', 'system', $current_tnc_version);
    $client_mf->save;

    $client_mx->set_status('tnc_approval', 'system', $current_tnc_version);
    $client_mx->save;

    $client_cr1->set_status('tnc_approval', 'system', $current_tnc_version);
    $client_cr1->set_default_account('JPY');
    $client_cr1->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has wrong default currency for landing_company')
        ->error_message_is('JPY transactions may not be performed with this account.', 'Correct error message for wrong default account');

    $client_cr->set_status('tnc_approval', 'system', $current_tnc_version);
    $client_cr->save;

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');
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
    $client_cr->set_status('cashier_locked', 'system');
    $client_cr->save;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has cashier lock')
        ->error_message_is('Your cashier is locked.', 'Correct error message for locked cashier');

    $client_cr->clr_status('cashier_locked');
    $client_cr->set_status('disabled', 'system');
    $client_cr->save;

    # as we check if client is disabled during token verification so it will not go to cashier
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('DisabledClient', 'Client is disabled')
        ->error_message_is('This account is unavailable.', 'Correct error message for disabled client');

    $client_cr->clr_status('disabled');
    $client_cr->cashier_setting_password('abc123');
    $client_cr->save;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has cashier password')
        ->error_message_is('Your cashier is locked as per your request.', 'Correct error message when cashier password is set');

    $client_cr->cashier_setting_password('');
    $client_cr->save;
};

subtest 'deposit' => sub {
    $client_cr->set_status('unwelcome', 'system');
    $client_cr->save;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client marked as unwelcome')
        ->error_message_is('Your account is restricted to withdrawals only.', 'Correct error message for client marked as unwelcome');

    $client_cr->clr_status('unwelcome');
    $client_cr->save;
};

subtest 'withdraw' => sub {
    $params->{args}->{cashier} = 'withdraw';

    $client_cr->set_status('withdrawal_locked', 'system', 'locked for security reason');
    $client_cr->save;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('ASK_EMAIL_VERIFY', 'Withdrawal needs verification token')
        ->error_message_is('Verify your withdraw request.', 'Withdrawal needs verification token');

    $params->{args}->{verification_code} = BOM::Platform::Token->new({
            email       => $client_cr->email,
            expires_in  => 3600,
            created_for => 'payment_withdraw',
        })->token;
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has withdrawal lock')
        ->error_message_is('Your account is locked for withdrawals.', 'Client is withdrawal locked');

    $client_cr->clr_status('withdrawal_locked');
    $client_cr->save;
};

subtest 'landing_companies_specific' => sub {
    $params->{args}->{cashier} = 'deposit';
    delete $params->{args}->{verification_code};

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mf->loginid, 'test token');

    $client_mf->set_default_account('EUR');
    $client_mf->save;

    my $assessment = $client_mf->financial_assessment();
    $client_mf->aml_risk_classification('high');
    $client_mf->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('FinancialAssessmentRequired',
        'MF client with High risk should have completed financial assessment')
        ->error_message_is('Please complete the financial assessment form to lift your withdrawal and trading limits.',
        'MF client with High risk should have completed financial assessment');

    $client_mf->aml_risk_classification('low');
    $client_mf->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_AUTHENTICATE', 'MF client needs to be fully authenticated')
        ->error_message_is('Please authenticate your account.', 'MF client needs to be fully authenticated');

    $client_mf->set_authentication('ID_DOCUMENT')->status('pass');
    $client_mf->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_FINANCIAL_RISK_APPROVAL', 'financial risk approval is required')
        ->error_message_is('Financial Risk approval is required.', 'financial risk approval is required');

    $client_mf->set_status('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
    $client_mf->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_TIN_INFORMATION', 'tax information is required for malatainvest')
        ->error_message_is('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.',
        'tax information is required for malatainvest');

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mx->loginid, 'test token');

    $client_mx->set_default_account('GBP');
    $client_mx->residence('gb');
    $client_mx->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_UK_FUNDS_PROTECTION', 'GB residence needs to accept fund protection')
        ->error_message_is('Please accept Funds Protection.', 'GB residence needs to accept fund protection');
    $client_mx->set_status('ukgc_funds_protection', 'system', 'testing');
    $client_mx->save;
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_SELF_EXCLUSION_MAX_TURNOVER_SET', 'GB residence needs to set 30-Day turnover')
        ->error_message_is('Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.',
        'GB residence needs to set 30-Day turnover');

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_jp->loginid, 'test token');
    $client_jp->set_default_account('JPY');
    $client_jp->residence('jp');
    my $current_tnc_version = BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version;
    $client_jp->set_status('tnc_approval',              'system', $current_tnc_version);
    $client_jp->set_status('jp_knowledge_test_pending', 'system', 'set for test');
    $client_jp->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_JP_KNOWLEDGE_TEST', 'Japan residence needs a knowledge test')
        ->error_message_is('You must complete the knowledge test to activate this account.', 'Japan residence needs a knowledge test');
    $client_jp->clr_status('jp_knowledge_test_pending');
    $client_jp->set_status('jp_knowledge_test_fail', 'system', 'set for test');
    $client_jp->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_JP_KNOWLEDGE_TEST', 'Japan residence needs a knowledge test')
        ->error_message_is('You must complete the knowledge test to activate this account.', 'Japan residence needs a knowledge test');

    $client_jp->clr_status('jp_knowledge_test_fail');
    $client_jp->set_status('jp_activation_pending', 'system', 'set for test');
    $client_jp->save;
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('JP_NOT_ACTIVATION', 'Japan residence needs account activation')
        ->error_message_is('Account not activated.', 'Japan residence needs account activation');

    $client_jp->clr_status('jp_activation_pending');
    $client_jp->save;
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('ASK_AGE_VERIFICATION', 'need age verification')
        ->error_message_is('Account needs age verification.', 'need verification');

};

subtest 'all status are covered' => sub {
    my $all_status = Client::Account::client_status_types;
    # Flags to represent state, rather than status for preventing cashier access:
    # * social signup, jp_transaction_detail, duplicate_account, migrated_single_email
    # * document_under_review, document_needs_action - for document_upload state
    # * professional, professional_requested
    # * ico_only
    my @temp_status =
        grep {
        $_ !~
            /^(?:social_signup|jp_transaction_detail|duplicate_account|migrated_single_email|document_under_review|document_needs_action|professional|professional_requested|ico_only)$/
        }
        keys %$all_status;
    fail("missing status $_") for sort grep !exists $seen{$_}, @temp_status;
    pass("ok to prevent warning 'no tests run");
    done_testing();
};

done_testing();
