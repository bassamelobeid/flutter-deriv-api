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

my $rule_name = 'cashier.is_not_locked';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    my %args = (loginid => $client->loginid);
    $client->status->set('cashier_locked', 'test', 'test');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CashierLocked',
        rule       => $rule_name
        },
        'Client is required for this rule';

    $client->status->clear_cashier_locked;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies without cashier lock status';
};

$rule_name = 'cashier.profile_requirements';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Action is required/, 'Action is required for this rule';

    my %args = (action => 'deposit');
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Client loginid is missing/, 'Client is required for this rule';

    $args{loginid} = $client->loginid;
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(
        missing_requirements => sub {
            my ($self, $action) = @_;
            my %requirements = (
                deposit    => [qw/first_name last_name/],
                withdrawal => [qw/date_of_birth citizen/]);
            return ($requirements{$action // ''} // [])->@*;
        });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CashierRequirementsMissing',
        details    => {fields => [qw/first_name last_name/]},
        rule       => $rule_name
        },
        'Correct error for missing deposit fields';

    $args{action} = 'withdrawal';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CashierRequirementsMissing',
        details    => {fields => [qw/date_of_birth citizen/]},
        rule       => $rule_name
        },
        'Correct error for missing withdrawal fields';

    $mock_client->unmock_all;
};

done_testing();
