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
use BOM::Test::Helper::ExchangeRates qw (populate_exchange_rates populate_exchange_rates_db);
use BOM::Test::Helper::P2P;

my $db = BOM::Database::ClientDB->new({broker_code => 'CR', operation => 'write'})->db->dbic;

$db->dbh->do(
    "INSERT INTO payment.doughflow_method (payment_processor, payment_method, reversible, withdrawal_supported) 
    VALUES ('reversible', 'reversible', TRUE, TRUE), ('can_wd', 'can_wd', FALSE, TRUE), ('no_wd', 'no_wd', FALSE, FALSE)"
);

my $rates = {ETH => 1000};
populate_exchange_rates($rates);
populate_exchange_rates_db($db, $rates);

BOM::Config::Runtime->instance->app_config->payments->pa_sum_deposits_limit(200);

my $agent_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'pa@test.com',
    residence   => 'in',
});
$agent_usd->account('USD');

BOM::User->create(
    email    => $agent_usd->email,
    password => 'xxx',
)->add_client($agent_usd);

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
    amount       => 10000,
    remark       => 'here is money',
    payment_type => 'ewallet',
);

my ($client_usd, $client_eth);

BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation(0);

subtest 'No deposits or PA is the only deposit method -> payment agent withdrawal allowed' => sub {

    create_clients('in');    # non blocked CFT country

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentZeroDeposits', 'Fiat account has error with empty account';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentZeroDeposits', 'Crypto account has error with empty account';

    # PA sends money to fiat client
    $agent_usd->payment_account_transfer(
        toClient           => $client_usd,
        currency           => 'USD',
        amount             => 500,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
        verification       => 'paymentagent_transfer',
    );

    is $client_usd->allow_paymentagent_withdrawal, undef,                      'Fiat account can withdraw with only PA deposit';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentZeroDeposits', 'Crypto account still cannot withdraw';

    # transfer all to crypto
    $client_usd->payment_account_transfer(
        toClient  => $client_eth,
        currency  => 'USD',
        amount    => 500,
        fees      => 0,
        to_amount => 0.5,
        remark    => 'x',
    );

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentZeroDeposits', 'Fiat account cannot withdraw after transferring to crypto';
    is $client_eth->allow_paymentagent_withdrawal, undef,                      'Crypto account can withdraw after transferring PA deposit';
};

subtest 'Visa - CFT NOT Blocked country' => sub {

    create_clients('in');    # non blocked CFT country
    pa_deposit_and_transfer();

    $client_usd->payment_doughflow(
        currency       => 'USD',
        amount         => 50,
        remark         => 'x',
        payment_method => 'VISA',
    );

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod', 'cannot withdraw from fiat account with net VISA deposit';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod', 'cannot withdraw from crypto account with net VISA deposit';

    $client_usd->payment_doughflow(
        currency       => 'USD',
        amount         => -50,
        remark         => 'x',
        payment_method => 'VISA',
    );

    is $client_usd->allow_paymentagent_withdrawal, undef, 'can withdraw from fiat account with zero net VISA deposit';
    is $client_eth->allow_paymentagent_withdrawal, undef, 'can withdraw from crypto account with zero net VISA deposit';
};

subtest 'Visa - CFT blocked country' => sub {

    create_clients('ca');    # CFT blocked country
    pa_deposit_and_transfer();

    $client_usd->payment_doughflow(
        currency       => 'USD',
        amount         => 50,
        remark         => 'x',
        payment_method => 'VISA',
    );

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentUseOtherMethod', 'cannot withdraw from fiat account with net VISA deposit';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentUseOtherMethod', 'cannot withdraw from crypto account with net VISA deposit';

    $client_usd->payment_doughflow(
        currency       => 'USD',
        amount         => -50,
        remark         => 'x',
        payment_method => 'VISA',
    );

    is $client_usd->allow_paymentagent_withdrawal, undef, 'can withdraw from fiat account with zero net VISA deposit';
    is $client_eth->allow_paymentagent_withdrawal, undef, 'can withdraw from crypto account with zero net VISA deposit';
};

subtest 'MasterCard' => sub {

    create_clients('in');
    pa_deposit_and_transfer();

    $client_usd->payment_doughflow(
        currency       => 'USD',
        amount         => 50,
        remark         => 'x',
        payment_method => 'MasterCard',
    );

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentUseOtherMethod', 'cannot withdraw from fiat account with net MC deposit';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentUseOtherMethod', 'cannot withdraw from crypto account with net MC deposit';

    $client_usd->payment_doughflow(
        currency       => 'USD',
        amount         => -50,
        remark         => 'x',
        payment_method => 'MasterCard',
    );

    is $client_usd->allow_paymentagent_withdrawal, undef, 'can withdraw from fiat account with zero net MC deposit';
    is $client_eth->allow_paymentagent_withdrawal, undef, 'can withdraw from crypto account with zero net MC deposit';
};

subtest 'Reversible method (NOT ZingPay) - CFT NOT Blocked country' => sub {

    create_clients('in');    # non blocked CFT country
    pa_deposit_and_transfer();

    $client_usd->payment_doughflow(
        currency          => 'USD',
        amount            => 50,
        remark            => 'x',
        payment_processor => 'reversible',
        payment_method    => 'reversible',
    );

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod', 'cannot withdraw from fiat account with net reversible deposit';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod',
        'cannot withdraw from crypto account with net reversible deposit';

    $client_usd->payment_doughflow(
        currency          => 'USD',
        amount            => -50,
        remark            => 'x',
        payment_processor => 'reversible',
        payment_method    => 'reversible',
    );

    is $client_usd->allow_paymentagent_withdrawal, undef, 'can withdraw from fiat account with zero net reversible deposit';
    is $client_eth->allow_paymentagent_withdrawal, undef, 'can withdraw from crypto account with zero net reversible deposit';
};

subtest 'Reversible method (NOT ZingPay) - CFT blocked country' => sub {

    create_clients('ca');    # blocked CFT country
    pa_deposit_and_transfer();

    $client_usd->payment_doughflow(
        currency          => 'USD',
        amount            => 50,
        remark            => 'x',
        payment_processor => 'reversible',
        payment_method    => 'reversible',
    );

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentUseOtherMethod', 'cannot withdraw from fiat account with net reversible deposit';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentUseOtherMethod', 'cannot withdraw from crypto account with net reversible deposit';

    $client_usd->payment_doughflow(
        currency          => 'USD',
        amount            => -50,
        remark            => 'x',
        payment_processor => 'reversible',
        payment_method    => 'reversible',
    );

    is $client_usd->allow_paymentagent_withdrawal, undef, 'can withdraw from fiat account with zero net reversible deposit';
    is $client_eth->allow_paymentagent_withdrawal, undef, 'can withdraw from crypto account with zero net reversible deposit';
};

subtest 'ZingPay' => sub {

    create_clients('in');    # non blocked CFT country
    pa_deposit_and_transfer();

    $client_usd->payment_doughflow(
        currency       => 'USD',
        amount         => 50,
        remark         => 'x',
        payment_method => 'ZingPay',
    );

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod', 'cannot withdraw from fiat account with net ZingPay deposit';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod', 'cannot withdraw from crypto account with net ZingPay deposit';

    $client_usd->payment_doughflow(
        currency       => 'USD',
        amount         => -50,
        remark         => 'x',
        payment_method => 'ZingPay',
    );

    is $client_usd->allow_paymentagent_withdrawal, undef, 'can withdraw from fiat account with zero net ZingPay deposit';
    is $client_eth->allow_paymentagent_withdrawal, undef, 'can withdraw from crypto account with zero net ZingPay deposit';
};

subtest 'Ireversible method - withdrawal_supported' => sub {

    create_clients('id');

    $client_usd->payment_doughflow(
        currency          => 'USD',
        amount            => 190,        # <200
        remark            => 'x',
        payment_method    => 'can_wd',
        payment_processor => 'can_wd',
    );

    # Transfer some to crypto
    $client_usd->payment_account_transfer(
        toClient  => $client_eth,
        currency  => 'USD',
        amount    => 50,
        fees      => 0,
        to_amount => 0.05,
        remark    => 'x',
    );

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentJustification', 'amount<200, no trade - PaymentAgentJustification on fiat account';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentJustification', 'amount<200, no trade - PaymentAgentJustification on crypto account';

    my $mock_client = Test::MockModule->new("BOM::User::Client");
    $mock_client->mock(get_sum_trades => sub { return 100; });

    is $client_usd->allow_paymentagent_withdrawal, undef, 'amount<200, has traded - fiat account can withdraw';
    is $client_eth->allow_paymentagent_withdrawal, undef, 'amount<200, has traded - crypto account can withdraw';

    $client_usd->payment_doughflow(
        currency          => 'USD',
        amount            => 100,
        remark            => 'x',
        payment_method    => 'can_wd',
        payment_processor => 'can_wd',
    );

    # sum of deposits became 190+100 = 290
    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod', 'amount>200 - PaymentAgentWithdrawSameMethod on fiat account';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod', 'amount>200 - PaymentAgentWithdrawSameMethod on crypto account';

    $client_usd->payment_doughflow(
        currency          => 'USD',
        amount            => -100,
        remark            => 'x',
        payment_method    => 'can_wd',
        payment_processor => 'can_wd',
    );

    is $client_usd->allow_paymentagent_withdrawal, undef, 'net deposit < 200 - fiat account can withdraw';
    is $client_eth->allow_paymentagent_withdrawal, undef, 'net deposit < 200 - crypto account can withdraw';
};

subtest 'Ireversible method - withdrawal option NOT available' => sub {

    create_clients('id');

    $client_usd->payment_doughflow(
        currency          => 'USD',
        amount            => 200,
        remark            => 'x',
        payment_method    => 'no_wd',
        payment_processor => 'no_wd',
    );

    # Transfer some to crypto
    $client_usd->payment_account_transfer(
        toClient  => $client_eth,
        currency  => 'USD',
        amount    => 50,
        fees      => 0,
        to_amount => 0.05,
        remark    => 'x',
    );

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentJustification', 'no trades - PaymentAgentJustification on fiat account';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentJustification', 'no trades - PaymentAgentJustification on crypto account';

    my $mock_client = Test::MockModule->new("BOM::User::Client");
    $mock_client->mock(get_sum_trades => sub { return 120; });

    is $client_usd->allow_paymentagent_withdrawal, undef, 'has traded - fiat account can withdraw';
    is $client_eth->allow_paymentagent_withdrawal, undef, 'has traded - crypto account can withdraw';
};

subtest 'Crypto' => sub {

    create_clients('id');

    $client_eth->payment_ctc(
        currency         => 'ETH',
        amount           => 10,
        crypto_id        => 1,
        address          => 'address1',
        transaction_hash => 'txhash1',
    );

    # Transfer some to fiat
    $client_eth->payment_account_transfer(
        toClient  => $client_usd,
        currency  => 'ETH',
        amount    => 0.01,
        fees      => 0,
        to_amount => 10,
        remark    => 'x',
    );

    is $client_usd->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod', 'no trades - PaymentAgentWithdrawSameMethod on fiat account';
    is $client_eth->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod', 'no trades - PaymentAgentWithdrawSameMethod on crypto account';

    my $mock_client = Test::MockModule->new("BOM::User::Client");
    $mock_client->mock(get_sum_trades => sub { return 5000; });

    is $client_usd->allow_paymentagent_withdrawal, undef, 'has traded - fiat account can withdraw';
    is $client_eth->allow_paymentagent_withdrawal, undef, 'has traded - crypto account can withdraw';
};

subtest 'P2P restricted country withdrawal' => sub {

    BOM::Test::Helper::P2P::create_escrow;
    BOM::Test::Helper::P2P::bypass_sendbird();
    my $config     = BOM::Config::Runtime->instance->app_config->payments;
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
    my $client     = BOM::Test::Helper::P2P::create_advertiser(balance => 500);
    my (undef, $ad) = BOM::Test::Helper::P2P::create_advert(
        client           => $advertiser,
        type             => 'buy',
        max_order_amount => 100,
        amount           => 100,
    );

    my (undef, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $ad->{id},
        amount    => 100
    );

    $advertiser->p2p_order_confirm(id => $order->{id});
    $client->p2p_order_confirm(id => $order->{id});

    BOM::Config::Runtime->instance->app_config->payments->pa_sum_deposits_limit(99);

    is $advertiser->allow_paymentagent_withdrawal, 'PaymentAgentWithdrawSameMethod',
        'If Deposit is from p2p and resident is not banned he can withdraw only from p2p';

    $config->p2p->restricted_countries(['ng']);
    $advertiser->residence('ng');

    is $advertiser->allow_paymentagent_withdrawal, undef, 'can withdraw as PA if p2p deposited and country residence is banned';

};

done_testing();

sub create_clients {
    my $country = shift;

    my $email = 'dummy' . rand(999) . '@binary.com';

    my $user = BOM::User->create(
        email    => $email,
        password => 'xxx',
    );

    $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        residence      => $country,
        binary_user_id => $user->id,
    });
    $client_usd->account('USD');

    $client_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        residence      => $country,
        binary_user_id => $user->id,
    });
    $client_eth->account('ETH');

    $user->add_client($client_usd);
    $user->add_client($client_eth);
}

sub pa_deposit_and_transfer {

    # PA sends money to fiat client
    $agent_usd->payment_account_transfer(
        toClient           => $client_usd,
        currency           => 'USD',
        amount             => 100,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
        verification       => 'paymentagent_transfer',
    );

    # Transfer half to crypto
    $client_usd->payment_account_transfer(
        toClient  => $client_eth,
        currency  => 'USD',
        amount    => 50,
        fees      => 0,
        to_amount => 0.05,
        remark    => 'x',
    );
}
