#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;

use Date::Utility;
use BOM::User::Client;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;
use BOM::Config::PaymentAgent;
use BOM::User;
use BOM::User::Password;
use BOM::Database::Model::OAuth;
use BOM::Database::ClientDB;
use BOM::Test::Helper::ExchangeRates qw (populate_exchange_rates);

populate_exchange_rates();

BOM::Database::ClientDB->new({broker_code => 'CR', operation => 'write'})->db->dbic->dbh->do(
    "INSERT INTO payment.doughflow_method (payment_processor, payment_method, reversible, withdrawal_supported) 
    VALUES ('reversible', 'reversible', TRUE, TRUE), ('can_wd', 'can_wd', FALSE, TRUE), ('no_wd', 'no_wd', FALSE, FALSE)"
);

BOM::Config::Runtime->instance->app_config->payments->pa_sum_deposits_limit(200);

my $agent_usd = new_client('in', 'USD');

#Create payment agent
$agent_usd->payment_agent({
    payment_agent_name    => 'Test Agent',
    currency_code         => 'USD',
    email                 => $agent_usd->email,
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    status                => 'authorized',
    target_country        => 'in',
});

$agent_usd->save;

$agent_usd->payment_legacy_payment(
    currency     => 'USD',
    amount       => 1000,
    remark       => 'here is money',
    payment_type => 'ewallet',
);

my $allow_withdraw;

BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation(0);

subtest '1- No deposits or PA is the only deposit method -> payment agent withdrawal allowed' => sub {

    my $client = new_client('in', 'USD');    # non blocked CFT country

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentZeroDeposits', '1-1- no deposits - do not allow PA withdrawal';

    # PA sends money to client
    $agent_usd->payment_account_transfer(
        toClient           => $client,
        currency           => 'USD',
        amount             => 500,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
        verification       => 'paymentagent_transfer',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, '1-2- PA is the only deposit method -> payment agent withdrawal allowed';
};

subtest '2- visa - CFT NOT Blocked' => sub {

    my $client = new_client('in', 'USD');    # non blocked CFT country

    # PA sends money to client
    $agent_usd->payment_account_transfer(
        toClient           => $client,
        currency           => 'USD',
        amount             => 1,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
        verification       => 'paymentagent_transfer',
    );

    $client->payment_doughflow(
        currency       => 'USD',
        amount         => 2,
        remark         => 'x',
        payment_method => 'VISA',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentWithdrawSameMethod', '2-1- PaymentAgentWithdrawSameMethod';

    $client->payment_doughflow(
        currency       => 'USD',
        amount         => -2,
        remark         => 'x',
        payment_method => 'VISA',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, 'Allowed when net visa deposit is zero';
};

subtest '3- visa - CFT blocked' => sub {

    my $client = new_client('ca', 'USD');    # blocked CFT country

    # PA sends money to client
    $agent_usd->payment_account_transfer(
        toClient           => $client,
        currency           => 'USD',
        amount             => 1,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
        verification       => 'paymentagent_transfer',
    );

    $client->payment_doughflow(
        currency       => 'USD',
        amount         => 3,
        remark         => 'x',
        payment_method => 'VISA',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentUseOtherMethod', '3-1- PaymentAgentUseOtherMethod';

    $client->payment_doughflow(
        currency       => 'USD',
        amount         => -3,
        remark         => 'x',
        payment_method => 'VISA',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, 'Allowed when net visa deposit is zero';
};

subtest '4- MasterCard' => sub {

    my $client = new_client('in', 'USD');

    # PA sends money to client
    $agent_usd->payment_account_transfer(
        toClient           => $client,
        currency           => 'USD',
        amount             => 1,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
        verification       => 'paymentagent_transfer',
    );

    $client->payment_doughflow(
        currency       => 'USD',
        amount         => 4,
        remark         => 'x',
        payment_method => 'MasterCard',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentUseOtherMethod', '4-1- not traded so ask for justification/same withdrawal method';

    $client->payment_doughflow(
        currency       => 'USD',
        amount         => -4,
        remark         => 'x',
        payment_method => 'MasterCard',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, 'Allowed when net mastercard deposit is zero';
};

subtest '6- Reversible - Acquired (NOT ZingPay) - CFT NOT Blocked' => sub {

    my $client = new_client('in', 'USD');    # non blocked CFT country

    # PA sends money to client
    $agent_usd->payment_account_transfer(
        toClient           => $client,
        currency           => 'USD',
        amount             => 1,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
        verification       => 'paymentagent_transfer',
    );

    $client->payment_doughflow(
        currency          => 'USD',
        amount            => 5,
        remark            => 'x',
        payment_processor => 'reversible',
        payment_method    => 'reversible',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentWithdrawSameMethod', '6-1- PaymentAgentWithdrawSameMethod';

    $client->payment_doughflow(
        currency          => 'USD',
        amount            => -5,
        remark            => 'x',
        payment_processor => 'reversible',
        payment_method    => 'reversible',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, 'Allowed when net deposit is zero';
};

subtest '7- Reversible - CardPay (NOT ZingPay) - CFT blocked' => sub {

    my $client = new_client('ca', 'USD');    # blocked CFT country

    # PA sends money to client
    $agent_usd->payment_account_transfer(
        toClient           => $client,
        currency           => 'USD',
        amount             => 1,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
        verification       => 'paymentagent_transfer',
    );

    $client->payment_doughflow(
        currency          => 'USD',
        amount            => 6,
        remark            => 'x',
        payment_processor => 'reversible',
        payment_method    => 'reversible',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentUseOtherMethod', '7-1- PaymentAgentUseOtherMethod';

    $client->payment_doughflow(
        currency          => 'USD',
        amount            => -6,
        remark            => 'x',
        payment_processor => 'reversible',
        payment_method    => 'reversible',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, 'Allowed when net reversible deposit is zero';

};

subtest '8- Reversible - ZingPay' => sub {

    my $client = new_client('in', 'USD');    # non blocked CFT country

    # PA sends money to client
    $agent_usd->payment_account_transfer(
        toClient           => $client,
        currency           => 'USD',
        amount             => 1,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
        verification       => 'paymentagent_transfer',
    );

    $client->payment_doughflow(
        currency       => 'USD',
        amount         => 7,
        remark         => 'x',
        payment_method => 'ZingPay',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentWithdrawSameMethod', '8-1-  PaymentAgentWithdrawSameMethod';

    $client->payment_doughflow(
        currency       => 'USD',
        amount         => -7,
        remark         => 'x',
        payment_method => 'ZingPay',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, 'Allowed when net zingpay deposit is zero';
};

subtest '9- Ireversible - withdrawal_supported' => sub {

    my $client = new_client('id', 'USD');

    $client->payment_doughflow(
        currency          => 'USD',
        amount            => 101,        # <200
        remark            => 'x',
        payment_method    => 'can_wd',
        payment_processor => 'can_wd',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentJustification', '9-1- no trade amount<200 - PaymentAgentWithdrawSameMethod';

    # sum of deposits : 101
    my $mock_client = Test::MockModule->new("BOM::User::Client");
    $mock_client->mock(get_sum_trades => sub { return 100; });

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, '9-2- allow paymentagent withdrawal';

    $client->payment_doughflow(
        currency          => 'USD',
        amount            => 100,
        remark            => 'x',
        payment_method    => 'can_wd',
        payment_processor => 'can_wd',
    );

    # sum of deposits became 101+100 = 201
    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentWithdrawSameMethod', '9-3- amount>200';

    $client->payment_doughflow(
        currency          => 'USD',
        amount            => -2,
        remark            => 'x',
        payment_method    => 'can_wd',
        payment_processor => 'can_wd',
    );

    # sum of deposits became 101+100-2 = 199
    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, 'net sum of deposits under limit';
};

subtest '10- Ireversible - withdrawal option NOT available' => sub {

    my $client = new_client('id', 'USD');

    $client->payment_doughflow(
        currency          => 'USD',
        amount            => 201,
        remark            => 'x',
        payment_method    => 'no_wd',
        payment_processor => 'no_wd',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentJustification', '10-1- not traded';

    my $mock_client = Test::MockModule->new("BOM::User::Client");
    $mock_client->mock(get_sum_trades => sub { return 120; });

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, '10-2- allow paymentagent withdrawal';
};

subtest '11- crypto' => sub {

    my $client = new_client('id', 'ETH');

    $client->payment_ctc(
        currency         => 'ETH',
        amount           => 10,
        crypto_id        => 1,
        address          => 'address1',
        transaction_hash => 'txhash1',
    );

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, 'PaymentAgentWithdrawSameMethod', '11-1- not traded so ask PaymentAgentWithdrawSameMethod';

    my $mock_client = Test::MockModule->new("BOM::User::Client");
    $mock_client->mock(get_sum_trades => sub { return 80; });

    $allow_withdraw = $client->allow_paymentagent_withdrawal;
    is $allow_withdraw, undef, '11-2- allow paymentagent withdrawal';
};

done_testing();

sub new_client {
    my ($country, $currency) = @_;

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'dummy' . rand(999) . '@binary.com',
        residence   => $country,
    });

    BOM::User->create(
        email    => $client->email,
        password => 'xxx',
    )->add_client($client);

    $client->account($currency);
    return $client;
}
