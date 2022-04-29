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
    # this also ensures we are calling BOM::Platform::Client::CashierValidation::validate
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

done_testing();
