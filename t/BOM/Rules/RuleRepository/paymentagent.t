use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;
use Test::MockTime qw( set_absolute_time restore_time);
use Format::Util::Numbers qw(financialrounding);

use ExchangeRates::CurrencyConverter qw/in_usd/;

use ExchangeRates::CurrencyConverter qw/in_usd/;
use Format::Util::Numbers qw(financialrounding);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $payment_agent_args = {
    payment_agent_name    => 'Test Agent',
    currency_code         => 'USD',
    url                   => 'http://www.example.com/',
    email                 => 'joe@example.com',
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    status                => 'authorized',
};
my $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client->payment_agent($payment_agent_args);
$pa_client->save;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
BOM::User->create(
    email    => 'rules_pa@test.deriv',
    password => 'TEST PASS',
)->add_client($client);

BOM::User->create(
    email    => 'rules_pa_already_exist@test.deriv',
    password => 'TEST PASS',
)->add_client($pa_client);

subtest 'rule paymentagent.pa_allowed_in_landing_company' => sub {
    my $rule_name = 'paymentagent.pa_allowed_in_landing_company';

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    lives_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'This landing company is allowed';

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });
    dies_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'This landing company is NOT allowed';
};

my $rule_name = 'paymentagent.paymentagent_shouldnt_already_exist';
subtest $rule_name => sub {

    my $rule_engine = BOM::Rules::Engine->new(client => $pa_client);
    dies_ok { $rule_engine->apply_rules($rule_name, loginid => $pa_client->loginid) } 'paymentagent already exists';
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
        params     => 'CR10000',
        },
        'Correct  error when payment agent is not authenticated';

    $mock_payment_agent->redefine(status => 'authorized');
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No error for authenticated PA';
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

done_testing();
