use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warnings qw(warning);

use MojoX::JSON::RPC::Client;
use URI;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::FinancialAssessment;
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;
use BOM::User::Password;
use BOM::Platform::Token;
use BOM::User;
use BOM::User::Client;
use BOM::User::Password;
use Email::Stuffer::TestLinks;

my $rpc_ct;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
my $status_mocked = Test::MockModule->new('BOM::User::Client::Status');
my @can_affect_cashier =
    ('age_verification', 'crs_tin_information', 'cashier_locked', 'disabled', 'financial_risk_approval', 'unwelcome', 'withdrawal_locked');

my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
my $documents_expired;
$documents_mock->mock(
    'expired',
    sub {
        my ($self) = @_;

        return $documents_expired if defined $documents_expired;
        return $documents_mock->original('expired')->(@_);
    });

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
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

my $params = {
    language => 'EN',
    source   => 1,
    args     => {},
    domain   => 'binary.com'
};

my $email = 'dummy' . rand(999) . '@binary.com';

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
my $client_cr_token = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token');

my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email,
});
$client_btc->account('BTC');
$user_client_cr->add_client($client_btc);
my $client_btc_token = BOM::Platform::Token::API->new->create_token($client_btc->loginid, 'test token');

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

subtest 'common' => sub {
    $params->{args}->{cashier} = 'deposit';
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');

    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Cashier forward error as client is virtual')
        ->error_message_is('This is a virtual-money account. Please switch to a real-money account to access cashier.',
        'Correct error message for virtual account');

    my $user_mocked = Test::MockModule->new('BOM::User');
    $user_mocked->mock('new', sub { bless {}, 'BOM::User' });

    $client_mocked->mock(is_tnc_approval_required => sub { 0 });

    $client_cr1->set_default_account('JPY');
    $client_cr1->save;

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has wrong default currency for landing_company')
        ->error_message_is('JPY transactions may not be performed with this account.', 'Correct error message for wrong default account');

    $params->{token} = $client_btc_token;
    $params->{args}{type} = 'url';
    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidRequest', '"type: url" is not supported for crypto accounts')
        ->error_message_is("Cashier API doesn't support the selected provider or operation.", 'Correct error message for wrong type: url (crypto)');

    $params->{token} = $client_cr_token;
    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('ASK_CURRENCY', 'Client has no default currency')
        ->error_message_is('Please set the currency.', 'Correct error message when currency is not set');

    $client_cr->set_default_account('USD');
    $client_cr->save;

    $params->{args}{type} = 'api';
    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidRequest', '"type: api" is not supported for fiat accounts')
        ->error_message_is("Cashier API doesn't support the selected provider or operation.", 'Correct error message for wrong type: api (fiat)');
    delete $params->{args}{type};

    $documents_expired = 1;

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client documents have expired')
        ->error_message_is('Your identity documents have expired. Visit your account profile to submit your valid documents and unlock your cashier.',
        'Correct error message for documents expired');

    $documents_expired = undef;
    $client_cr->status->set('cashier_locked', 'system');

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has cashier lock')
        ->error_message_is('Your cashier is locked.', 'Correct error message for locked cashier');

    $client_cr->status->clear_cashier_locked;
    $client_cr->status->set('disabled', 'system');

    # as we check if client is disabled during token verification so it will not go to cashier
    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('DisabledClient', 'Client is disabled')
        ->error_message_is('This account is unavailable.', 'Correct error message for disabled client');

    $client_cr->status->clear_disabled;
    $client_cr->save;

    # Sometimes we do not get domain in params, so in that case we will set domain to valid default.
    $params->{domain} = undef;
    warning {
        $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Domain not provided')
            ->error_message_is('Sorry, an error occurred. Please try accessing our cashier again.',
            'Attempted to forward request to the cashier to default dogflow url when Domain not provided.');
    };
    # set domain to valid default incase invalid domain is provided
    $params->{domain} = 'dummydomain.com';
    warning {
        $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Invalid domain provided')
            ->error_message_is('Sorry, an error occurred. Please try accessing our cashier again.',
            'Attempted to forward request to the cashier to default dogflow url when Domain is not whitelisted.');
    };
    # set valid domain
    $params->{domain} = 'binary.com';
    warning {
        $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Valid domain provided')
            ->error_message_is('Sorry, an error occurred. Please try accessing our cashier again.',
            'Attempted to forward request to the cashier after setting whitelisted domain:binary.com.');
    };
    # set valid domain
    $params->{domain} = 'binary.me';
    warning {
        $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Valid domain provided')
            ->error_message_is('Sorry, an error occurred. Please try accessing our cashier again.',
            'Attempted to forward request to the cashier after setting whitelisted domain:binary.me.');
    };
    # set valid domain
    $params->{domain} = 'deriv.com';
    warning {
        $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Valid domain provided')
            ->error_message_is('Sorry, an error occurred. Please try accessing our cashier again.',
            'Attempted to forward request to the cashier after setting whitelisted domain:deriv.app.');
    };

};

subtest 'deposit' => sub {
    $params->{token}  = $client_cr_token;
    $params->{domain} = 'binary.com';

    $runtime_system->suspend->payments(1);
    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Cashier is suspended')
        ->error_message_is('Sorry, cashier is temporarily unavailable due to system maintenance.',
        'Correct error message for deposit when payments are suspended.');
    $runtime_system->suspend->payments(0);

    $runtime_system->suspend->cashier(1);
    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Cashier is suspended')
        ->error_message_is('Sorry, cashier is temporarily unavailable due to system maintenance.',
        'Correct error message for deposit when cashier is suspended.');
    $runtime_system->suspend->cashier(0);

    $client_cr->status->set('unwelcome', 'system');
    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client marked as unwelcome')
        ->error_message_is('Your account is restricted to withdrawals only.', 'Correct error message for client marked as unwelcome');
    $client_cr->status->clear_unwelcome;

    $runtime_system->suspend->cryptocashier(1);
    warning {
        $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_internal_message_like(qr/Error with DF CreateCustomer/,
            'Fiat client can access cashier when cryptocashier is suspended');
    };
    $runtime_system->suspend->cryptocashier(0);

};

subtest 'withdraw' => sub {
    $params->{token} = $client_cr_token;
    $params->{args}->{cashier} = 'withdraw';

    $client_cr->status->set('withdrawal_locked', 'system', 'locked for security reason');

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('ASK_EMAIL_VERIFY', 'Withdrawal needs verification token')
        ->error_message_is('Verify your withdraw request.', 'Withdrawal needs verification token');

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token1');
    $params->{args}->{verification_code} = BOM::Platform::Token->new({
            email       => $client_cr->email,
            expires_in  => 3600,
            created_for => 'payment_withdraw',
        })->token;

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Client has withdrawal lock')
        ->error_message_is('Your account is locked for withdrawals.', 'Client is withdrawal locked');

    $client_cr->status->clear_withdrawal_locked;
};

subtest 'landing_companies_specific' => sub {
    $params->{args}->{cashier} = 'deposit';
    delete $params->{args}->{verification_code};

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mf->loginid, 'test token1');

    $client_mf->set_default_account('EUR');
    $client_mf->save;

    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_code_is('FinancialAssessmentRequired',
        'MF client has to complete financial assessment irrespective of risk classification')->error_message_is(
        'Please complete the financial assessment form to lift your withdrawal and trading limits.',
        'MF client has to complete financial assessment irrespective of risk classification'
        );

    $client_mf->financial_assessment({data => BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa()});
    $client_mf->save();
    $client_mocked->mock(has_deposits => sub { 1 });
    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_code_is('ASK_AUTHENTICATE', 'MF client needs to be fully authenticated')
        ->error_message_is('Please authenticate your account.', 'MF client needs to be fully authenticated');

    $client_mocked->mock(has_deposits => sub { undef });
    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_code_is('ASK_FINANCIAL_RISK_APPROVAL', 'financial risk approval is required')
        ->error_message_is('Financial Risk approval is required.', 'financial risk approval is required');

    $client_mocked->mock(has_deposits => sub { 0 });
    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_code_is('ASK_FINANCIAL_RISK_APPROVAL', 'financial risk approval is required')
        ->error_message_is('Financial Risk approval is required.', 'financial risk approval is required');

    $client_mf->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client_mf->save;

    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_code_is('ASK_FINANCIAL_RISK_APPROVAL', 'financial risk approval is required')
        ->error_message_is('Financial Risk approval is required.', 'financial risk approval is required');

    $client_mf->status->set('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');

    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_code_is('ASK_TIN_INFORMATION', 'tax information is required for malatainvest')
        ->error_message_is('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.',
        'tax information is required for malatainvest');
};

subtest 'all status are covered' => sub {
    # Flags that can affect cashier should be seen
    my @can_affect_cashier =
        ('age_verification', 'crs_tin_information', 'cashier_locked', 'disabled', 'financial_risk_approval', 'unwelcome', 'withdrawal_locked');
    fail("missing status $_") for sort grep !exists $seen{$_}, @can_affect_cashier;
    pass("ok to prevent warning 'no tests run");
    done_testing();
};

done_testing();
