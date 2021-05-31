use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $rule_engine = BOM::Rules::Engine->new(client => $client);

subtest 'rule currency.is_currency_suspended' => sub {
    my $rule_name = 'currency.is_currency_suspended';

    lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule applies with empty args.';

    my $mock_currency = Test::MockModule->new('BOM::Config::CurrencyConfig');
    my $suspended     = 0;
    $mock_currency->redefine(is_crypto_currency_suspended => sub { return $suspended });

    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'GBP'}) } 'Rule applies with a fiat currency.';
    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) } 'Rule applies if the crypto is not suspended.';

    $suspended = 1;
    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'GBP'}) } 'Rule applies with a fiat currency when cyrpto is suspended.';
    is_deeply exception { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) },
        {
        code   => 'CurrencySuspended',
        params => 'BTC'
        },
        'Rule fails to apply on a suspended crypto currency.';

    $mock_currency->redefine('is_crypto_currency_suspended' => sub { die 'Dying to test!' });
    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'GBP'}) } 'Rule applies with a fiat currency even crypto check dies.';
    is_deeply exception { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) },
        {
        code   => 'InvalidCryptoCurrency',
        params => 'BTC'
        },
        'Rule fails to apply on a failing crypto currency.';

    $mock_currency->unmock_all;
};

subtest 'rule currency.experimental_currency' => sub {
    my $rule_name = 'currency.experimental_currency';

    my @test_cases = ({
            experimental   => 0,
            allowed_emails => [],
            description    => 'If currency is not experimental, rule always applies.',
        },
        {
            experimental   => 1,
            allowed_emails => [],
            error          => 'ExperimentalCurrency',
            description    => 'If currency is experimental and client email is not included, rule fails.',
        },
        {
            experimental   => 1,
            allowed_emails => [$client->email],
            description    => 'If currency is experimental and client email is included, rule applies.',
        });

    my $case;
    my $mock_config = Test::MockModule->new('BOM::Config::CurrencyConfig');
    $mock_config->redefine(is_experimental_currency => sub { return $case->{experimental} });

    my $mock_runtime = Test::MockModule->new(ref BOM::Config::Runtime->instance->app_config->payments);
    $mock_runtime->redefine(experimental_currencies_allowed => sub { return $case->{allowed_emails} });
    for $case (@test_cases) {
        $mock_config->redefine(is_experimental_currency => sub { return $case->{experimental} });
        $mock_runtime->redefine(experimental_currencies_allowed => sub { return $case->{allowed_emails} });

        lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule always applies if there is no currency in args.';

        if ($case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) },
                {
                code => $case->{error},
                },
                $case->{description};
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) } $case->{description};
        }
    }

    $mock_config->unmock_all;
    $mock_runtime->unmock_all;
};

done_testing();
