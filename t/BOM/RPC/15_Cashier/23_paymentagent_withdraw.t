use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::User;
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Cashier;
use BOM::Config::Runtime;

my $client = BOM::Test::Helper::Client::create_client();
BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

my $app_config = BOM::Config::Runtime->instance->app_config;

$client->account('USD');
$client->save();
$app_config->system->suspend->payment_agents(0);

my $mock_trans_validation = Test::MockModule->new('BOM::Transaction::Validation');
$mock_trans_validation->mock(allow_paymentagent_withdrawal_legacy => sub { 0 });

subtest 'check payment_agent_withdrawal suspended' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation(1);
    for my $type (qw(paymentagent_withdraw)) {
        cmp_deeply(
            BOM::RPC::v3::Cashier::payment_agent_withdrawal_automation($client),
            {
                error => {
                    code              => 'PaymentAgentWithdrawError',
                    message_to_client => 'You are not authorized for withdrawals via payment agents.'
                }
            },
            'pa withdraw not allowed has error for ' . $type
        );
        is BOM::RPC::v3::Cashier::payment_agent_withdrawal_automation($client, $type, 1), undef,
            'no error with source_bypass_verification for ' . $type;
    }
};

subtest 'check payment_agent_withdrawal NOT suspended' => sub {
    $client->status->set('pa_withdrawal_explicitly_allowed', 'system', 'enable withdrawal through payment agent');
    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation(0);
    is BOM::RPC::v3::Cashier::payment_agent_withdrawal_automation($client), undef,
        'no error with source_bypass_verification for paymentagent_withdraw';
};

done_testing();
