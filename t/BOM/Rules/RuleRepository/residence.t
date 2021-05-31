use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new(
    residence       => 'id',
    landing_company => 'svg'
);

subtest 'rule residence.market_type_is_available' => sub {
    my $rule_name      = 'residence.market_type_is_available';
    my $companies      = {};
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(
        gaming_company_for_country    => sub { return $companies->{synthetic} },
        financial_company_for_country => sub { return $companies->{financial} });

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'InvalidAccount'},
        'correct error when market_type in not specified in args';

    my $args = {market_type => 'synthetic'};
    is_deeply exception { $rule_engine->apply_rules($rule_name), $args }, {code => 'InvalidAccount'},
        'correct error when there is no matching landing_company';
    $companies->{synthetic} = 'abcd';
    is_deeply exception { $rule_engine->apply_rules($rule_name), $args }, {code => 'InvalidAccount'},
        'Fails if the landing company matching market type is different form context landing company';

    $companies->{synthetic} = 'svg';
    lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Succeeds after setting the same landing company';

    $args = {market_type => 'financial'};
    is_deeply exception { $rule_engine->apply_rules($rule_name), $args }, {code => 'InvalidAccount'},
        'correct error when there is no matching landing_company';
    $companies->{financial} = 'maltainvest';
    is_deeply exception { $rule_engine->apply_rules($rule_name), $args }, {code => 'InvalidAccount'},
        'Fails if the landing company matching market type is different form context landing company';

    $companies->{financial} = 'svg';
    lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Succeeds after setting the same landing company';

    $mock_countries->unmock_all;
};

subtest 'rule residence.not_restricted' => sub {
    my $rule_name      = 'residence.not_restricted';
    my $is_restricted  = 1;
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(restricted_country => sub { return $is_restricted });

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'InvalidResidence'}, 'correct error when the country is restricted';
    $is_restricted = 0;
    lives_ok { $rule_engine->apply_rules($rule_name) } 'rule apples if the country is not restricted';

    $mock_countries->unmock_all;
};

subtest 'rule residence.is_signup_allowed' => sub {
    my $rule_name      = 'residence.is_signup_allowed';
    my $is_allowed     = 0;
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(is_signup_allowed => sub { return $is_allowed });

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'InvalidAccount'}, 'correct error when signup is not allowed';
    $is_allowed = 1;
    lives_ok { $rule_engine->apply_rules($rule_name) } 'rule apples if signup is allowed';

    $mock_countries->unmock_all;
};

done_testing;
