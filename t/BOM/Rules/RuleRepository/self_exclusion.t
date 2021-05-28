use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;
use Syntax::Keyword::Try;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;
use BOM::User;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $rule_name = 'self_exclusion.not_self_excluded';
subtest "rule $rule_name" => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my $excluded_until = '2000-01-02';
    my $mock_client    = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine('get_self_exclusion_until_date' => sub { return $excluded_until });
    is_deeply exception { $rule_engine->apply_rules($rule_name) },
        {
        code   => 'SelfExclusion',
        params => $excluded_until,
        },
        'Client is already self-excluded';

    $excluded_until = 0;
    lives_ok { $rule_engine->apply_rules($rule_name) } 'Client is not self-excluded nows';

    $mock_client->unmock_all;
};

$rule_name = 'self_exclusion.deposit_limits_allowed';
subtest "rule $rule_name" => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my $deposit_limit_allowed = 0;
    my $mock_company          = Test::MockModule->new('LandingCompany');
    $mock_company->redefine('deposit_limit_enabled' => sub { return $deposit_limit_allowed });

    my $args = {a => 1234};

    for (0 .. 1) {
        $deposit_limit_allowed = $_;
        lives_ok { $rule_engine->apply_rules($rule_name) } "Args are empty - no deposit limit - allowed: $_";
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } "Still no deposit limit - allowed: $_";
    }

    for my $limit (qw/max_deposit max_7day_deposit max_30day_deposit/) {
        $args = {$limit => 1};

        $deposit_limit_allowed = 0;
        is_deeply exception { $rule_engine->apply_rules($rule_name, $args) },
            {
            code    => 'SetSelfExclusionError',
            details => $limit,
            },
            "Fails with depist limit: $limit";

        $deposit_limit_allowed = 1;
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } "No failure if deposit limts are allowed: $limit";
    }

    $mock_company->unmock_all;
};

done_testing();
