use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

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

BOM::User->create(
    email    => 'rules_pa_already_exist@test.deriv',
    password => 'TEST PASS',
)->add_client($pa_client);

subtest 'rule paymentagent.pa_allowed_in_landing_company' => sub {
    my $rule_name = 'paymentagent.pa_allowed_in_landing_company';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    BOM::User->create(
        email    => 'rules_pa@test.deriv',
        password => 'TEST PASS',
    )->add_client($client);

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    lives_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'This landing company is allowed';

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });
    dies_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'This landing company is NOT allowed';
};

subtest 'rule paymentagent.paymentagent_shouldnt_already_exist' => sub {
    my $rule_name = 'paymentagent.paymentagent_shouldnt_already_exist';

    my $rule_engine = BOM::Rules::Engine->new(client => $pa_client);
    dies_ok { $rule_engine->apply_rules($rule_name, loginid => $pa_client->loginid) } 'paymentagent already exists';
};

my $rule_name = 'paymentagent.daily_transfer_limits';
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
        params     => 'CR10000',
        },
        'Correct  error when payment agent is not authenticated';

    $mock_payment_agent->redefine(status => 'authorized');
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No error for authenticated PA';
};

done_testing();
