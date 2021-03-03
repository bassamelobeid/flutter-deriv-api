use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new(residence => 'id');

subtest 'rule residence.account_type_is_allowed' => sub {
    my $rule_name      = 'residence.account_type_is_allowed';
    my $companies      = {};
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(
        gaming_company_for_country    => sub { return $companies->{real} },
        financial_company_for_country => sub { return $companies->{financial} });

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'InvalidAccount'}, 'correct error when there is no account type in args';

    $companies->{financial} = 'abcd';
    my $args = {account_type => 'real'};
    is_deeply exception { $rule_engine->apply_rules($rule_name), $args }, {code => 'InvalidAccount'},
        'correct error when there is no matching landing_company';
    $companies->{real} = 'abcd';
    lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Succeeds after setting a landing company';

    $args = {account_type => 'financial'};
    is_deeply exception { $rule_engine->apply_rules($rule_name), $args }, {code => 'InvalidAccount'},
        'correct error when there is no matching landing_company';
    $companies->{financial} = 'abcd';
    is_deeply exception { $rule_engine->apply_rules($rule_name), $args }, {code => 'InvalidAccount'},
        'correct error when financial company is invalid';
    $companies->{financial} = 'maltainvest';
    lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'financial accounts are allowed in maltainvest only';

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

subtest 'rule residence.date_of_birth_complies_minimum_age' => sub {
    my $rule_name = 'residence.date_of_birth_complies_minimum_age';
    my $minimum_age;
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(minimum_age_for_country => sub { return $minimum_age });

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'InvalidDateOfBirth'},
        'correct error when there is no date of birth in args';

    my $args = {date_of_birth => 'abcd'};
    is_deeply exception { $rule_engine->apply_rules($rule_name, $args) }, {code => 'InvalidDateOfBirth'}, 'correct error for invalid date of birth';

    $args = {date_of_birth => Date::Utility->new(time)->minus_time_interval('10y')};
    is_deeply exception { $rule_engine->apply_rules($rule_name, $args) }, {code => 'InvalidResidence'},
        'correct error when there is no minimum age configured';

    $minimum_age = 10;
    lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'rule apples if date of birth matches the allowed minimum age';

    $args->{date_of_birth} = $args->{date_of_birth}->plus_time_interval('1d');
    is_deeply exception { $rule_engine->apply_rules($rule_name, $args) }, {code => 'BelowMinimumAge'},
        'correct error when client is younger than minimum age';

    $mock_countries->unmock_all;
};

done_testing;
