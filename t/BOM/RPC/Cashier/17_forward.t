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
use BOM::System::Password;
use BOM::Platform::Token;
use BOM::Platform::User;
use Client::Account;

my ($t, $rpc_ct);
my $client_mocked = Test::MockModule->new('Client::Account');
my %seen;
$client_mocked->mock(
    'set_status',
    sub {
        my $status = $_[1];
        $seen{$status}++;
        return $client_mocked->original('set_status')->(@_);
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

my $method = 'cashier';
subtest 'common' => sub {
    $params->{args}->{cashier} = 'deposit';
    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_vr->loginid, 'test token');

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Cashier forward error as client is virtual')
        ->error_message_is('This is a virtual-money account. Please switch to a real-money account to deposit funds.',
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
    $client_mocked->mock('documents_expired', sub { return 1 });

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client documents have expired')
        ->error_message_is(
        'Your identity documents have passed their expiration date. Kindly send a scan of a valid ID to <a href="mailto:support@binary.com">support@binary.com</a> to unlock your cashier.',
        'Correct error message for documents expired'
        );

    $client_mocked->unmock('documents_expired');
    $client_cr->set_status('cashier_locked', 'system');
    $client_cr->save;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has cashier lock')
        ->error_message_is('Your cashier is locked', 'Correct error message for locked cashier');

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

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('ASK_CURRENCY', 'Client has no default currency')
        ->error_message_is('Please set the currency.', 'Correct error message when currency is not set');

    $client_cr->set_default_account('USD');
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

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has withdrawal lock')
        ->error_message_is('Your account is locked for withdrawals. Please contact customer service.', 'Client is withdrawal locked');

    $client_cr->clr_status('withdrawal_locked');
    $client_cr->save;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('ASK_EMAIL_VERIFY', 'Withdrawal needs verification token')
        ->error_message_is('Verify your withdraw request.', 'Withdrawal needs verification token');

};

subtest 'landing_companies_specific' => sub {
    $params->{args}->{cashier} = 'deposit';
    delete $params->{args}->{verification_code};

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mf->loginid, 'test token');

    $client_mf->set_default_account('EUR');
    $client_mf->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_AUTHENTICATE', 'MF client needs to be fully authenticated')
        ->error_message_is('Client is not fully authenticated.', 'MF client needs to be fully authenticated');

    $client_mf->set_authentication('ID_DOCUMENT')->status('pass');
    $client_mf->save;

    $rpc_ct->call_ok($method, $params)
          ->has_no_system_error->has_error->error_code_is('ASK_FINANCIAL_RISK_APPROVAL', 'financial risk approval is required')
          ->error_message_is('Financial Risk approval is required.', 'financial risk approval is required');

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mx->loginid, 'test token');

    $client_mx->set_default_account('GBP');
    $client_mx->residence('gb');
    $client_mx->save;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ASK_UK_FUNDS_PROTECTION', 'GB residence needs to accept fund protection')
        ->error_message_is('Please accept Funds Protection.', 'GB residence needs to accept fund protection');

};

subtest 'all status are covered' => sub {
    my $all_status = Client::Account::client_status_types;
    my %all_status = %$all_status;
    my @ignored_status = qw(age_verification);
    delete @all_status{@ignored_status};
    fail("missing status $_") for sort grep !exists $seen{$_}, keys %all_status;
    done_testing();
};

done_testing();
