use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;
use Syntax::Keyword::Try;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;
use BOM::User;

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $user = BOM::User->create(
    email    => 'rules_user@test.deriv',
    password => 'TEST PASS',
);
$user->add_client($client_cr);

subtest 'rule user.has_no_enabled_clients_without_currency' => sub {
    my $rule_name   = 'user.has_no_real_clients_without_currency';
    my $rule_engine = BOM::Rules::Engine->new(landing_company => 'malta');
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client is missing/, 'Client is required for this rule';

    $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    is_deeply exception { $rule_engine->apply_rules($rule_name) },
        {
        code   => 'SetExistingAccountCurrency',
        params => $client_cr->loginid
        },
        'Correct error when currency is not set';

    $client_cr->set_default_account('USD');
    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $user->add_client($client_cr2);
    is_deeply exception { $rule_engine->apply_rules($rule_name) },
        {
        code   => 'SetExistingAccountCurrency',
        params => $client_cr2->loginid
        },
        'Sibling account has not currency';
    $client_cr2->status->set('disabled', 'test', 'test');
    lives_ok { $rule_engine->apply_rules($rule_name) }, 'Disabled accounts are ignored';
};

subtest 'rule user.currency_is_available' => sub {
    my $rule_name   = 'user.currency_is_available';
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

    subtest 'trading  account' => sub {
        lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule applies if currency arg is empty';
        my $args = {
            currency     => 'EUR',
            account_type => 'trading'
        };
        is_deeply exception { $rule_engine->apply_rules($rule_name, $args) }, {code => 'CurrencyTypeNotAllowed'}, 'Only one fiat account is allowed';

        my $mock_account = Test::MockModule->new('BOM::User::Client::Account');
        $mock_account->redefine(currency_code => sub { return 'BTC' });
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Rule applies if the existing account is crypto';

        $args->{currency} = 'BTC';
        is_deeply exception { $rule_engine->apply_rules($rule_name, $args) },
            {
            code   => 'DuplicateCurrency',
            params => 'BTC'
            },
            'The same currency cannot be used again';

        $args->{currency} = 'ETH';
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Other crypto currency is allowed';
        $mock_account->unmock_all;

        $rule_engine = BOM::Rules::Engine->new(
            client          => $client_cr,
            landing_company => 'malta'
        );
        $args->{currency} = 'USD';
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'No problem in a diffrent landing company';
    };

    subtest 'wallet account' => sub {
        my $args = {
            account_type   => 'wallet',
            currency       => 'USD',
            payment_method => 'Skrill',
        };
        is $client_cr->account->currency_code(), 'USD', 'There is a trading sibling with USD currency';

        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Wallet with the same currency as the trading account is allowed';

        # Note: It's not possible to create real wallet accounts in test scripts at the moment.
        #       So it will be simulated by mocking
        my $mock_client = Test::MockModule->new('BOM::User::Client');
        $mock_client->redefine(
            is_wallet      => sub { 1 },
            payment_method => sub { 'Skrill' });

        $args->{currecy} = $client_cr->account->currency_code;
        is_deeply exception { $rule_engine->apply_rules($rule_name, $args) },
            {
            code   => 'DuplicateWallet',
            params => 'USD'
            },
            'Duplicate wallet is detected';

        $args->{payment_method} = 'Paypal';
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Currency is available with a different payment method';

        $args->{currency} = 'EUR';
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'A different currency is accpeted';

        $mock_client->unmock_all;
    };
};

subtest 'user.email_is_verified' => sub {
    my $rule_name = 'user.email_is_verified';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

    my $mock_user      = Test::MockModule->new('BOM::User');
    my $email_verified = 1;
    $mock_user->redefine(email_verified => sub { return $email_verified });

    lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule applies when email is verified';

    $email_verified = 0;
    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'email unverified'}, 'Rule fails when email is verified';

    $mock_user->unmock_all;
};

done_testing();
