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
    my $rule_name = 'user.currency_is_available';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule applies if currency arg is empty';

    is_deeply exception { $rule_engine->apply_rules($rule_name, {currency => 'EUR'}) }, {code => 'CurrencyTypeNotAllowed'},
        'Only one fiat account is allowed';

    my $mock_account = Test::MockModule->new('BOM::User::Client::Account');
    $mock_account->redefine(currency_code => sub { return 'BTC' });
    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'EUR'}) } 'Rule applies if the existing account is crypto';

    is_deeply exception { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) },
        {
        code   => 'DuplicateCurrency',
        params => 'BTC'
        },
        'The same currency cannot be used again';
    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'ETH'}) } 'Other crypto currency is allowed';
    $mock_account->unmock_all;

    $rule_engine = BOM::Rules::Engine->new(
        client          => $client_cr,
        landing_company => 'malta'
    );
    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'USD'}) } 'No problem in a diffrent landing company';
};

done_testing();
