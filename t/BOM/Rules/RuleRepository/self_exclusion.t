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
my $rule_engine = BOM::Rules::Engine->new(client => $client);

my $rule_name = 'self_exclusion.not_self_excluded';
subtest "rule $rule_name" => sub {
    like exception { $rule_engine->apply_rules($rule_name) }, qr//, 'loginid is required';

    my $args           = {loginid => $client->loginid};
    my $excluded_until = '2000-01-02';
    my $mock_client    = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine('get_self_exclusion_until_date' => sub { return $excluded_until });
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'SelfExclusion',
        params     => [$excluded_until],
        rule       => $rule_name,
        details    => {excluded_until => $excluded_until}
        },
        'Client is already self-excluded';

    $excluded_until = 0;
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Client is not self-excluded nows';

    $mock_client->unmock_all;
};

$rule_name = 'self_exclusion.deposit_limits_allowed';
subtest "rule $rule_name" => sub {

    my $deposit_limit_allowed = 0;
    my $mock_company          = Test::MockModule->new('LandingCompany');
    $mock_company->redefine('deposit_limit_enabled' => sub { return $deposit_limit_allowed });

    my $args = {loginid => $client->loginid};

    like exception { $rule_engine->apply_rules($rule_name) }, qr//, 'loginid is required';

    for (0 .. 1) {
        $deposit_limit_allowed = $_;
        lives_ok { $rule_engine->apply_rules($rule_name, %$args) } "Args are empty - no deposit limit - allowed: $_";
    }

    for my $limit (qw/max_deposit max_7day_deposit max_30day_deposit/) {
        $args = {
            loginid => $client->loginid,
            $limit  => 1
        };

        $deposit_limit_allowed = 0;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
            {
            error_code => 'SetSelfExclusionError',
            details    => $limit,
            rule       => $rule_name
            },
            "Fails with depist limit: $limit";

        $deposit_limit_allowed = 1;
        lives_ok { $rule_engine->apply_rules($rule_name, %$args) } "No failure if deposit limts are allowed: $limit";
    }

    $mock_company->unmock_all;
};

$rule_name = 'self_exclusion.sibling_account_not_excluded';
subtest "rule $rule_name" => sub {
    like exception { $rule_engine->apply_rules($rule_name) }, qr//, 'loginid is required';

    my $args           = {loginid => $client->loginid};
    my $excluded_until = Date::Utility->new->plus_time_interval('1d')->epoch;
    my $date_until     = Date::Utility->new->plus_time_interval('1d')->date;
    my $sibiling       = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'not+legal+currency@test.deriv',
        password => 'TRADING PASS',
    );
    $sibiling->set_exclusion->timeout_until($excluded_until);
    $user->add_client($client);
    $user->add_client($sibiling);
    # Assuming get_siblings returns an arrayref of sibling accounts
    my $mock_context = Test::MockModule->new('BOM::Rules::Context');
    $mock_context->redefine('client_siblings' => sub { return [$sibiling] });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'SelfExclusion',
        params     => [$date_until],
        rule       => $rule_name,
        details    => {excluded_until => $date_until}
        },
        'Sibling account is already self-excluded';

    $excluded_until = 0;
    $sibiling->set_exclusion->timeout_until($excluded_until);
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Sibling account is not self-excluded now';
    $mock_context->unmock_all;
};

done_testing();
