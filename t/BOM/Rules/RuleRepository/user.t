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
        error_code => 'SetExistingAccountCurrency',
        params     => $client_cr->loginid
        },
        'Correct error when currency is not set';

    $client_cr->set_default_account('USD');
    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $user->add_client($client_cr2);
    is_deeply exception { $rule_engine->apply_rules($rule_name) },
        {
        error_code => 'SetExistingAccountCurrency',
        params     => $client_cr2->loginid
        },
        'Sibling account has not currency';
    $client_cr2->status->set('disabled', 'test', 'test');
    lives_ok { $rule_engine->apply_rules($rule_name) }, 'Disabled accounts are ignored';
};

subtest 'user.email_is_verified' => sub {
    my $rule_name = 'user.email_is_verified';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

    my $mock_user      = Test::MockModule->new('BOM::User');
    my $email_verified = 1;
    $mock_user->redefine(email_verified => sub { return $email_verified });

    lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule applies when email is verified';

    $email_verified = 0;
    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {error_code => 'email unverified'}, 'Rule fails when email is verified';

    $mock_user->unmock_all;
};

done_testing();
