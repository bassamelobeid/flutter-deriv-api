use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;
use Test::Warnings                             qw(warning);
use Test::MockTime                             qw( set_absolute_time restore_time);
use Format::Util::Numbers                      qw(financialrounding);
use ExchangeRates::CurrencyConverter           qw/in_usd/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;
use BOM::Rules::RuleRepository::Paymentagent;
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;

my $app_config = BOM::Config::Runtime->instance->app_config;

BOM::Test::Helper::P2P::bypass_sendbird;
BOM::Test::Helper::P2P::create_escrow;

my $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client->payment_agent({
    payment_agent_name    => 'Joe',
    email                 => 'joe@example.com',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    status                => 'authorized',
    currency_code         => 'USD',
    is_listed             => 't',
});
$pa_client->save;
$pa_client->get_payment_agent->set_countries(['id', 'pk']);
my $pa = $pa_client->get_payment_agent;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $user = BOM::User->create(
    email    => 'rules_pa3@test.deriv',
    password => 'TEST PASS',
);
$user->add_client($pa_client);
$user->add_client($client);

my $rule_name = 'paymentagent.pa_allowed_in_landing_company';
subtest $rule_name => sub {
    BOM::User->create(
        email    => 'rules_pa@test.deriv',
        password => 'TEST PASS',
    )->add_client($client);

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    lives_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'This landing company is allowed';

    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    dies_ok { $rule_engine->apply_rules($rule_name, loginid => $client_mf->loginid) } 'This landing company is NOT allowed';
};

$rule_name = 'paymentagent.paymentagent_status_can_apply_for_pa';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => [$pa_client, $client]);

    lives_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'Pass for non-PA client';

    $pa->status('rejected');
    lives_ok { $rule_engine->apply_rules($rule_name, loginid => $pa_client->loginid) } 'Pass for PA with status rejected';

    $pa->status('applied');
    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, loginid => $pa_client->loginid) },
        {
            rule       => $rule_name,
            error_code => 'PaymentAgentAlreadyApplied',
        },
        'Fail with PaymentAgentAlreadyApplied for PA with status applied'
    );

    for my $status (qw(authorized verified)) {
        $pa->status($status);
        is_deeply(
            exception { $rule_engine->apply_rules($rule_name, loginid => $pa_client->loginid) },
            {
                rule       => $rule_name,
                error_code => 'PaymentAgentAlreadyExists',
            },
            "Fail with PaymentAgentAlreadyExists for PA with status $status"
        );
    }

    $pa->status('suspended');
    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, loginid => $pa_client->loginid) },
        {
            rule       => $rule_name,
            error_code => 'PaymentAgentStatusNotEligible',
        },
        'Fail with PaymentAgentAlreadyApplied for PA with status suspended'
    );

    $pa->status('authorized');
};

$rule_name = 'paymentagent.client_status_can_apply_for_pa';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => [$client]);

    $client->status->_clear_all;
    lives_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'Pass with no status';

    for my $status (qw(cashier_locked shared_payment_method no_withdrawal_or_trading withdrawal_locked unwelcome duplicate_account)) {
        $client->status->set($status, 'x', 'x');

        is_deeply(
            exception { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) },
            {
                rule       => $rule_name,
                error_code => 'PaymentAgentClientStatusNotEligible',
            },
            "Fail with PaymentAgentClientStatusNotEligible for client with status $status"
        );

        my $func = "clear_$status";
        $client->status->$func;
    }
};

$rule_name = 'paymentagent.client_has_mininum_deposit';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => [$client]);

    $client->db->dbic->dbh->do('DELETE FROM payment.doughflow_method');
    $client->db->dbic->dbh->do(
        "INSERT INTO payment.doughflow_method (payment_processor, reversible, withdrawal_supported) VALUES ('my_method', TRUE, TRUE)");

    $client->payment_doughflow(
        currency          => $client->currency,
        remark            => 'x',
        amount            => 500,
        payment_processor => 'my_method',
    );

    $client->payment_doughflow(
        currency          => $client->currency,
        remark            => 'x',
        amount            => 4,
        payment_processor => 'other_method',
    );

    $app_config->payment_agents->initial_deposit_per_country('{}');

    lives_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'Pass with no limit set';

    $app_config->payment_agents->initial_deposit_per_country('{ "default": 5, "xx": 1 }');

    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) },
        {
            rule       => $rule_name,
            error_code => 'PaymentAgentInsufficientDeposit',
            params     => ['USD', '5.00'],
        },
        "Fail with PaymentAgentInsufficientDeposit when global limit not met"
    );

    $client->payment_doughflow(
        currency          => $client->currency,
        remark            => 'x',
        amount            => 1,
        payment_processor => 'other_method',
    );

    lives_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'Pass when global limit met';

    $app_config->payment_agents->initial_deposit_per_country('{ "default": 5, "' . $client->residence . '": 6 }');

    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) },
        {
            rule       => $rule_name,
            error_code => 'PaymentAgentInsufficientDeposit',
            params     => ['USD', '6.00'],
        },
        "Fail with PaymentAgentInsufficientDeposit when country limit not met"
    );

    $client->payment_doughflow(
        currency          => $client->currency,
        remark            => 'x',
        amount            => 1,
        payment_processor => 'other_method',
    );

    lives_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'Pass when country limit met';

    $client->p2p_advertiser_create(name => 'x');
    $client->p2p_advertiser_update(is_approved => 1);

    my ($advertiser, $ad)    = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my (undef,       $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        client    => $client,
        amount    => 10
    );
    $client->p2p_order_confirm(id => $order->{id});
    $advertiser->p2p_order_confirm(id => $order->{id});

    $app_config->payment_agents->initial_deposit_per_country('{ "default": 5, "' . $client->residence . '": 15 }');

    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) },
        {
            rule       => $rule_name,
            error_code => 'PaymentAgentInsufficientDeposit',
            params     => ['USD', '15.00'],
        },
        'P2P deposit is excluded'
    );
};

$rule_name = 'paymentagent.action_is_allowed';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(
        client => [$client, $pa_client],
        user   => $user
    );
    $pa_client->account('USD');

    my $mock_pa  = Test::MockModule->new('BOM::User::Client::PaymentAgent');
    my $services = {};
    $mock_pa->redefine(tier_details => sub { $services });

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Action name is required/, 'Action name is required';

    my %args = (action => 'dummy action');
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Action name is required/, 'Action name is not read from action args.';

    $args{underlying_action} = 'dummy action';
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/loginid is required/, 'Loginid is required';

    $args{loginid} = $pa_client->loginid;
    is exception { $rule_engine->apply_rules($rule_name, %args) }, undef, 'underlying_action argument is accepted as acation name';
    delete $args{underlying_action};

    $args{rule_engine_context} = {action => 'dummy action'};
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'It passes if context action name doesnt match any restricted service';
    delete $args{rule_engine_context};

    $args{$_} = $pa_client->loginid for qw(loginid_pa loginid_client);    # to make pa transfer fail

    my %error_mapping = (
        transfer_to_pa             => 'TransferToOtherPA',
        transfer_to_non_pa_sibling => 'TransferToNonPaSibling',
    );

    for my $action_name (
        qw/p2p cashier_withdraw withdraw buy p2p_advert_create p2p_order_create p2p_advertiser_create
        p2p.advert.create p2p_order.create p2p.advertiser.create transfer_to_pa paymentagent_transfer doughflow_withdrawal/
        )
    {
        $args{underlying_action} = $action_name;

        my $service_name = BOM::Rules::RuleRepository::Paymentagent::PA_ACTION_MAPPING->{$action_name =~ s/\./_/rg} // $action_name;

        $pa->status(undef);
        $pa->save();
        is_deeply warning { $rule_engine->apply_rules($rule_name, %args) }, [], "No error or warning when the PA status is undefined";

        $pa->status('suspended');
        $pa->save;
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } "Action $action_name is allowed if the PA is not authorized";

        $pa->status('authorized');
        $pa->save;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            rule       => $rule_name,
            error_code => $error_mapping{$service_name} // 'ServiceNotAllowedForPA'
            },
            "Action $action_name is not allowed - service $service_name is restricted";

        $services = {$service_name => 1};
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } "Action $action_name is allowed now - service $service_name is unlocked";
        $services = {};
    }

    delete $args{underlying_action};
    $args{rule_engine_context} = {action => 'account_transfer'};
    $args{transfer_type}       = 'internal';
    $args{loginid_from}        = $pa_client->loginid;
    $args{loginid_to}          = $client->loginid;
    ok exception { $rule_engine->apply_rules($rule_name, %args) }, 'transfer_between_accounts to non-PA sibling is blocked';

    $args{loginid_to} = $pa_client->loginid;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } "transfer_between_accounts is allowed to a PA sibling";

    for my $type ('mt5', 'dxtrade') {
        $args{transfer_type} = $type;
        $services = {};

        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args) },
            {
                error_code => 'ServiceNotAllowedForPA',
                rule       => $rule_name,
            },
            "$type transfer blocked when tier has trading permission",
        );

        $services = {trading => 1};
        is exception { $rule_engine->apply_rules($rule_name, %args) }, undef, "$type transfer allowed when tier has trading permission";
    }

    $services = {};
    delete $args{rule_engine_context};

    $args{underlying_action} = 'paymentagent_transfer';
    $args{loginid_client}    = $pa_client->loginid;
    ok exception { $rule_engine->apply_rules($rule_name, %args) }, 'paymentagent_transfer to another PA is blocked';
    $args{loginid_client} = $client->loginid;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } "paymentagent_transfer is allowed with a non-PA client";

    subtest 'commission withdrawal' => sub {

        my $limits;
        $mock_pa->redefine(cashier_withdrawable_balance => sub { $limits });

        my $usd_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => 'aff1@test.com'
        });
        BOM::User->create(
            email    => $usd_client->email,
            password => 'x'
        )->add_client($usd_client);
        $usd_client->account('USD');
        $usd_client->payment_agent({
            payment_agent_name => 'bob1',
            status             => 'authorized',
        });

        my $rule_engine = BOM::Rules::Engine->new(client => $usd_client);

        my %args = (
            underlying_action => 'doughflow_withdrawal',
            loginid           => $usd_client->loginid,
        );

        $limits = {
            available  => 0,
            commission => 0,
            payouts    => 0,
        };

        is_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args) },
            {
                rule       => $rule_name,
                error_code => 'ServiceNotAllowedForPA',
            },
            'Error is ServiceNotAllowedForPA with no available and no commission'
        );

        $limits = {
            available  => 0,
            commission => 1,
            payouts    => 0,
        };

        is_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args, amount => 12) },
            {
                rule       => $rule_name,
                error_code => 'PACommisionWithdrawalLimit',
                params     => ['USD', '0.00'],
            },
            'Error is PACommisionWithdrawalLimit when commission was received'
        );

        $limits = {
            available  => 10,
            commission => 10,
            payouts    => 0,
        };

        is_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args, amount => 10.01) },
            {
                rule       => $rule_name,
                error_code => 'PACommisionWithdrawalLimit',
                params     => ['USD', '10.00'],
            },
            'Error when amount exceeds available'
        );

        lives_ok { $rule_engine->apply_rules($rule_name, %args, amount => 10) } 'Allowed to withdraw full amount';

        my $usdc_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => 'aff2@test.com'
        });
        BOM::User->create(
            email    => $usdc_client->email,
            password => 'x'
        )->add_client($usdc_client);
        $usdc_client->account('USDC');
        $usdc_client->payment_agent({
            payment_agent_name => 'bob2',
            status             => 'authorized',
        });

        $rule_engine = BOM::Rules::Engine->new(client => $usdc_client);

        %args = (
            underlying_action => 'crypto_cashier_withdrawal',
            loginid           => $usdc_client->loginid,
        );

        $limits = {
            available  => 0,
            commission => 1,
            payouts    => 0,
        };

        is_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args, amount => 10.01) },
            {
                rule       => $rule_name,
                error_code => 'PACommisionWithdrawalLimit',
                params     => ['USDC', '0.00'],
            },
            'Crypto PA gets PACommisionWithdrawalLimit'
        );
    };
};

$rule_name = 'paymentagent.daily_transfer_limits';
subtest "rule $rule_name" => sub {
    my %mock_rates = (
        USD => 1,
        EUR => 1.6,
        BTC => 50000,
        ETH => 1000,
    );
    my $mock_currencyconverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
    $mock_currencyconverter->redefine(
        in_usd => sub {
            my ($amount, $currency) = @_;
            return $amount * $mock_rates{$currency};
        });

    my $transfer_limit = BOM::Config::payment_agent()->{transaction_limits}->{transfer};
    my $rule_engine    = BOM::Rules::Engine->new(client => $pa_client);
    for my $currency (sort keys %mock_rates) {
        # convert  to limit amount to  the currenct  currency
        my $limit_in_currency = $transfer_limit->{amount_in_usd_per_day} / ExchangeRates::CurrencyConverter::in_usd(1, $currency);

        my @mock_sum_count = ($limit_in_currency / 2, $transfer_limit->{transactions_per_day} - 1);
        my $mock_client    = Test::MockModule->new('BOM::User::Client');
        $mock_client->redefine(today_payment_agent_withdrawal_sum_count => sub { return @mock_sum_count });

        my %args = (
            loginid  => $pa_client->loginid,
            currency => $currency,
            amount   => $limit_in_currency / 2,
            action   => 'transfer'
        );
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } "Rule applies when the accumulated amount is equal to daily limit - $currency";

        $mock_sum_count[1] += 1;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            rule       => 'paymentagent.daily_transfer_limits',
            error_code => 'PaymentAgentDailyCountExceeded'
            },
            "Correct error for transfer count limit - $currency";
        $mock_sum_count[1] -= 1;

        # decrease the amount limit with 1 USD
        $mock_sum_count[0] += 1 / ExchangeRates::CurrencyConverter::in_usd(1, $currency);
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            rule       => $rule_name,
            error_code => 'PaymentAgentDailyAmountExceeded',
            params     => [$currency, financialrounding('amount', $currency, $limit_in_currency)]
            },
            "Correct error for transfer amout limit - $currency";

        $mock_client->unmock_all;
    }
    $mock_currencyconverter->unmock_all;

};

$rule_name = 'paymentagent.accounts_are_not_the_same';
subtest "rule $rule_name" => sub {
    my $rule_engine = BOM::Rules::Engine->new();

    my %args = (
        loginid_pa     => '123',
        loginid_client => '123'
    );
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        rule       => $rule_name,
        error_code => 'ClientsAreTheSame'
        },
        'Correct  error when loginids are the same';

    $args{loginid_client} = '321';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No error with different loginids';
};

$rule_name = 'paymentagent.is_authorized';
subtest "rule $rule_name" => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $pa_client);
    my %args        = (loginid => $pa_client->loginid);

    my $mock_payment_agent = Test::MockModule->new('BOM::User::Client::PaymentAgent');
    $mock_payment_agent->redefine(status => 'suspended');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        rule       => $rule_name,
        error_code => 'NotAuthorized',
        params     => $pa_client->loginid,
        },
        'Correct  error when payment agent is not authenticated';

    $mock_payment_agent->redefine(status => 'authorized');
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No error for authenticated PA';
};

$rule_name = 'paymentagent.daily_transfer_limits';
subtest "rule $rule_name" => sub {
    my %mock_rates = (
        USD => 1,
        EUR => 1.6,
        BTC => 50000,
        ETH => 1000,
    );
    my $mock_currencyconverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
    $mock_currencyconverter->redefine(
        in_usd => sub {
            my ($amount, $currency) = @_;
            return $amount * $mock_rates{$currency};
        });

    subtest 'transfer action' => sub {
        my $transfer_limit = BOM::Config::payment_agent()->{transaction_limits}->{transfer};
        my $rule_engine    = BOM::Rules::Engine->new(client => $pa_client);
        for my $currency (sort keys %mock_rates) {
            # convert  to limit amount to  the currenct  currency
            my $limit_in_currency = $transfer_limit->{amount_in_usd_per_day} / ExchangeRates::CurrencyConverter::in_usd(1, $currency);

            my @mock_sum_count = ($limit_in_currency / 2, $transfer_limit->{transactions_per_day} - 1);
            my $mock_client    = Test::MockModule->new('BOM::User::Client');
            $mock_client->redefine(today_payment_agent_withdrawal_sum_count => sub { return @mock_sum_count });

            my %args = (
                loginid  => $pa_client->loginid,
                currency => $currency,
                amount   => $limit_in_currency / 2,
                action   => 'transfer'
            );
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } "Rule applies when the accumulated amount is equal to daily limit - $currency";

            $mock_sum_count[1] += 1;
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                {
                rule       => 'paymentagent.daily_transfer_limits',
                error_code => 'PaymentAgentDailyCountExceeded'
                },
                "Correct error for transfer count limit - $currency";
            $mock_sum_count[1] -= 1;

            # decrease the amount limit with 1 USD
            $mock_sum_count[0] += 1 / ExchangeRates::CurrencyConverter::in_usd(1, $currency);
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                {
                rule       => $rule_name,
                error_code => 'PaymentAgentDailyAmountExceeded',
                params     => [$currency, financialrounding('amount', $currency, $limit_in_currency)]
                },
                "Correct error for transfer amout limit - $currency";

            $mock_client->unmock_all;
        }
    };

    subtest 'withdraw action' => sub {
        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my %test_times = (
            weekend => '2022-01-01T08:10:00Z',    # saturday
            weekday => '2022-01-03T08:10:00Z',    # monday

        );
        for my $day_type (qw/weekend weekday/) {
            set_absolute_time($test_times{$day_type});
            my $transfer_limit = BOM::Config::payment_agent()->{transaction_limits}->{withdraw}->{$day_type};

            for my $currency (sort keys %mock_rates) {
                # convert  to limit amount to  the currenct  currency
                my $limit_in_currency = $transfer_limit->{amount_in_usd_per_day} / ExchangeRates::CurrencyConverter::in_usd(1, $currency);

                my @mock_sum_count = ($limit_in_currency / 2, $transfer_limit->{transactions_per_day} - 1);
                my $mock_client    = Test::MockModule->new('BOM::User::Client');
                $mock_client->redefine(today_payment_agent_withdrawal_sum_count => sub { return @mock_sum_count });

                my %args = (
                    loginid  => $client->loginid,
                    currency => $currency,
                    amount   => $limit_in_currency / 2,
                    action   => 'withdraw'
                );
                lives_ok { $rule_engine->apply_rules($rule_name, %args) }
                "Rule applies when the accumulated amount is equal to daily limit - $currency";

                $mock_sum_count[1] += 1;
                is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                    {
                    rule       => 'paymentagent.daily_transfer_limits',
                    error_code => 'PaymentAgentDailyCountExceeded'
                    },
                    "Correct error for transfer count limit - $currency";
                $mock_sum_count[1] -= 1;

                # decrease the amount limit with 1 USD
                $mock_sum_count[0] += 1 / ExchangeRates::CurrencyConverter::in_usd(1, $currency);
                is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                    {
                    rule       => $rule_name,
                    error_code => 'PaymentAgentDailyAmountExceeded',
                    params     => [$currency, financialrounding('amount', $currency, $limit_in_currency)]
                    },
                    "Correct error for transfer amout limit - $currency";

                $mock_client->unmock_all;
            }    # for currency

            restore_time();
        }    # for day_type

    };    # subtest

    $mock_currencyconverter->unmock_all;
};

$rule_name = 'paymentagent.accounts_are_not_the_same';
subtest "rule $rule_name" => sub {
    my $rule_engine = BOM::Rules::Engine->new();

    my %args = (
        loginid_pa     => '123',
        loginid_client => '123'
    );
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        rule       => $rule_name,
        error_code => 'ClientsAreTheSame'
        },
        'Correct  error when loginids are the same';

    $args{loginid_client} = '321';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No error with different loginids';
};

$rule_name = 'paymentagent.amount_is_within_pa_limits';
subtest "rule $rule_name" => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $pa_client);

    my %args = (
        currency   => 'USD',
        amount     => 10,
        loginid_pa => $pa_client->loginid,
    );

    my $pa = $pa_client->get_payment_agent;
    # pa limits
    $pa->min_withdrawal(10);
    $pa->max_withdrawal(20);
    $pa->save;

    for my $amount (10, 15, 20) {
        $args{amount} = $amount;
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No error if value is within the limits';
    }

    for my $amount (0, 9, 21, 1000) {
        $args{amount} = $amount;
        cmp_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code => 'PaymentAgentNotWithinLimits',
            rule       => $rule_name,
            params     => [num(10), num(20)]
            },
            "Amount $amount is ourside the PA's limits";
    }

    # configured limits
    my $mock_config = Test::MockModule->new('BOM::Config::PaymentAgent');
    $mock_config->redefine(
        get_transfer_min_max => {
            minimum => 30,
            maximum => 40
        });
    $pa->min_withdrawal(0);
    $pa->max_withdrawal(0);
    $pa->save;

    for my $amount (30, 35, 40) {
        $args{amount} = $amount;
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No error if value is within the limits';
    }

    for my $amount (0, 29, 41, 2000) {
        $args{amount} = $amount;
        cmp_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code => 'PaymentAgentNotWithinLimits',
            rule       => $rule_name,
            params     => [num(30), num(40)]
            },
            "Amount $amount is ourside the configured limits";
    }

    $mock_config->unmock_all;
};

$rule_name = 'paymentagent.paymentagent_withdrawal_allowed';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    my %args       = (loginid => $client->loginid);
    my $mock_class = Test::MockModule->new('BOM::User::Client');

    # testing legacy code

    $app_config->system->suspend->payment_agent_withdrawal_automation(1);

    $client->status->set('pa_withdrawal_explicitly_allowed', 'sarah', 'enable withdrawal through payment agent');

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule passes if pa_withdrawal_explicitly_allowed';

    $client->status->clear_pa_withdrawal_explicitly_allowed;

    $mock_class->redefine(allow_paymentagent_withdrawal_legacy => undef);

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule passes if allow_paymentagent_withdrawal_legacy passes';

    $mock_class->redefine(allow_paymentagent_withdrawal_legacy => 1);

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'PaymentagentWithdrawalNotAllowed',
        rule       => $rule_name
        },
        'Correct error when allow_paymentagent_withdrawal_legacy returns an error';

    $args{source_bypass_verification} = 1;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule passes if client verifications are bypassed';
    $args{source_bypass_verification} = 0;

    ## new automation

    $app_config->system->suspend->payment_agent_withdrawal_automation(0);

    $client->status->set('pa_withdrawal_explicitly_allowed', 'sarah', 'enable withdrawal through payment agent');

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule passes if pa_withdrawal_explicitly_allowed';

    $client->status->clear_pa_withdrawal_explicitly_allowed;

    $mock_class->redefine(allow_paymentagent_withdrawal => undef);

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule passes if allow_paymentagent_withdrawal passes';

    $mock_class->redefine(allow_paymentagent_withdrawal => 'PaymentAgentWithdrawSameMethod');

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'PaymentAgentWithdrawSameMethod',
        rule       => $rule_name
        },
        'Correct error when allow_paymentagent_withdrawal returns an error';

    $mock_class->redefine(allow_paymentagent_withdrawal => undef);
    $args{source_bypass_verification} = 1;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule passes if client verifications are bypassed';

    $mock_class->unmock_all;
};

done_testing();
