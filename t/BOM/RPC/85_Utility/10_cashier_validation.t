use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::User;
use BOM::RPC::v3::Utility;
use BOM::Config::Runtime;

my $client = BOM::Test::Helper::Client::create_client();
BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

my $app_config = BOM::Config::Runtime->instance->app_config;

subtest 'tnc acceptance' => sub {
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(is_tnc_approval_required => sub { 1 });

    for my $type (qw(deposit)) {
        is BOM::RPC::v3::Utility::cashier_validation($client, $type)->{error}{code}, 'ASK_TNC_APPROVAL', 'TNC approval required for ' . $type;
    }

    for my $type (qw(paymentagent_withdraw payment_withdraw withdraw)) {
        isnt BOM::RPC::v3::Utility::cashier_validation($client, $type)->{error}{code}, 'ASK_TNC_APPROVAL', 'TNC approval not required for ' . $type;
    }
};

subtest 'no account currency' => sub {
    # this is also ensures we are calling BOM::Platform::Client::CashierValidation::validate
    for my $type (qw(deposit paymentagent_withdraw payment_withdraw withdraw)) {
        is BOM::RPC::v3::Utility::cashier_validation($client, $type)->{error}{code}, 'ASK_CURRENCY', 'Account currency required for ' . $type;
    }
};

subtest 'all clear' => sub {
    $client->account('USD');
    for my $type (qw(deposit paymentagent_withdraw payment_withdraw withdraw)) {
        is BOM::RPC::v3::Utility::cashier_validation($client, $type), undef, 'No error for ' . $type;
    }
};

subtest 'compliance checks' => sub {
    my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
    $mock_utility->mock(validation_checks => sub { 'dummy' });

    for my $type (qw(deposit withdraw payment_withdraw)) {
        is BOM::RPC::v3::Utility::cashier_validation($client, $type), 'dummy', 'Compliance checks required for ' . $type;
    }

    for my $type (qw(paymentagent_withdraw)) {
        is BOM::RPC::v3::Utility::cashier_validation($client, $type), undef, 'Compliance checks not required for ' . $type;
    }
};

subtest 'disable cashier' => sub {
    my $mock_config = Test::MockModule->new('BOM::Config::CurrencyConfig');
    $mock_config->mock(is_cashier_suspended => sub { 1 });

    for my $type (qw(deposit withdraw payment_withdraw)) {
        cmp_deeply(
            BOM::RPC::v3::Utility::cashier_validation($client, $type),
            {
                error => {
                    code              => 'CashierForwardError',
                    message_to_client => 'Sorry, cashier is temporarily unavailable due to system maintenance.'
                }
            },
            'cashier suspended has error for ' . $type
        );
    }

    for my $type (qw(paymentagent_withdraw)) {
        cmp_deeply(
            BOM::RPC::v3::Utility::cashier_validation($client, $type),
            {
                error => {
                    code              => 'CashierForwardError',
                    message_to_client => 'Sorry, cashier is temporarily unavailable due to system maintenance.'
                }
            },
            'cashier suspended has error for ' . $type
        );
    }
};

subtest 'payment agent specific rules' => sub {
    $app_config->system->suspend->payment_agents(1);

    for my $type (qw(paymentagent_withdraw)) {
        cmp_deeply(
            BOM::RPC::v3::Utility::cashier_validation($client, $type),
            {
                error => {
                    code              => 'PaymentAgentWithdrawError',
                    message_to_client => 'Sorry, this facility is temporarily disabled due to system maintenance.'
                }
            },
            'payment agents disabled has error for ' . $type
        );
    }

    for my $type (qw(deposit withdraw payment_withdraw)) {
        is BOM::RPC::v3::Utility::cashier_validation($client, $type), undef, 'payment agents disabled has no error for ' . $type;
    }

    $app_config->system->suspend->payment_agents(0);

    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->mock(allows_payment_agents => sub { 0 });

    for my $type (qw(paymentagent_withdraw)) {
        cmp_deeply(
            BOM::RPC::v3::Utility::cashier_validation($client, $type),
            {
                error => {
                    code              => 'PaymentAgentWithdrawError',
                    message_to_client => 'Payment agent facilities are not available for this account.'
                }
            },
            'landing company prohibits payment agents has error for ' . $type
        );
    }

    for my $type (qw(deposit withdraw payment_withdraw)) {
        is BOM::RPC::v3::Utility::cashier_validation($client, $type), undef, 'landing company prohibits payment agents has no error for ' . $type;
    }

    $mock_lc->unmock_all;

    my $mock_trans_validation = Test::MockModule->new('BOM::Transaction::Validation');
    $mock_trans_validation->mock(allow_paymentagent_withdrawal => sub { 0 });

    for my $type (qw(paymentagent_withdraw)) {
        cmp_deeply(
            BOM::RPC::v3::Utility::cashier_validation($client, $type),
            {
                error => {
                    code              => 'PaymentAgentWithdrawError',
                    message_to_client => 'You are not authorized for withdrawals via payment agents.'
                }
            },
            'pa withdraw not allowed has error for ' . $type
        );
        is BOM::RPC::v3::Utility::cashier_validation($client, $type, 1), undef, 'no error with source_bypass_verification for ' . $type;
    }

    for my $type (qw(deposit withdraw payment_withdraw)) {
        is BOM::RPC::v3::Utility::cashier_validation($client, $type), undef, 'pa withdraw not allowed has no error for ' . $type;
    }

};

done_testing();
