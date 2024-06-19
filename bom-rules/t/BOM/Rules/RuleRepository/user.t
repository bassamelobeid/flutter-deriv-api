use strict;
use warnings;
no indirect;

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

my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

subtest 'rule user.has_no_enabled_clients_without_currency' => sub {
    my $rule_name = 'user.has_no_real_clients_without_currency';

    my $args = {landing_company => 'svg'};
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    $args->{loginid} = $client_cr->loginid;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code  => 'SetExistingAccountCurrency',
        params      => $client_cr->loginid,
        rule        => $rule_name,
        description => 'Currency for ' . $client_cr->loginid . ' needs to be set'
        },
        'Correct error when currency is not set';

    $client_cr->set_default_account('USD');
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Passed after setting currency';

    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $user->add_client($client_cr2);
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code  => 'SetExistingAccountCurrency',
        params      => $client_cr2->loginid,
        rule        => $rule_name,
        description => 'Currency for ' . $client_cr2->loginid . ' needs to be set'
        },
        'Sibling account has not currency';
    $client_cr2->status->set('disabled', 'test', 'test');
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) }, 'Disabled accounts are ignored';
};

subtest 'user.email_is_verified' => sub {
    my $rule_name = 'user.email_is_verified';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';
    my $args = {loginid => $client_cr->loginid};

    my $mock_user      = Test::MockModule->new('BOM::User');
    my $email_verified = 1;
    $mock_user->redefine(email_verified => sub { return $email_verified });

    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rule applies when email is verified';

    $email_verified = 0;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code  => 'email unverified',
        rule        => $rule_name,
        description => 'Email address is not verified for user'
        },
        'Rule fails when email is verified';

    $mock_user->unmock_all;
};

done_testing();
