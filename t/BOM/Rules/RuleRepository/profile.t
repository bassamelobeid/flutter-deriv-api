use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new(residence => 'id');

subtest 'rule profile.date_of_birth_complies_minimum_age' => sub {
    my $rule_name = 'profile.date_of_birth_complies_minimum_age';
    my $minimum_age;
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(minimum_age_for_country => sub { return $minimum_age });

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {error_code => 'InvalidDateOfBirth'},
        'correct error when there is no date of birth in args';

    my $args = {date_of_birth => 'abcd'};
    is_deeply exception { $rule_engine->apply_rules($rule_name, $args) }, {error_code => 'InvalidDateOfBirth'},
        'correct error for invalid date of birth';

    $args = {date_of_birth => Date::Utility->new(time)->minus_time_interval('10y')};
    is_deeply exception { $rule_engine->apply_rules($rule_name, $args) }, {error_code => 'InvalidResidence'},
        'correct error when there is no minimum age configured';

    $minimum_age = 10;
    lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'rule apples if date of birth matches the allowed minimum age';

    $args->{date_of_birth} = $args->{date_of_birth}->plus_time_interval('1d');
    is_deeply exception { $rule_engine->apply_rules($rule_name, $args) }, {error_code => 'BelowMinimumAge'},
        'correct error when client is younger than minimum age';

    $mock_countries->unmock_all;
};

subtest 'rule profile.secret_question_with_answer' => sub {
    my $rule_name = 'profile.secret_question_with_answer';

    lives_ok { $rule_engine->apply_rules($rule_name) } 'rule apples with empty args.';

    lives_ok { $rule_engine->apply_rules($rule_name, {secret_answer => 'dummy'}) } 'rule apples with secret answer alone.';

    is_deeply exception { $rule_engine->apply_rules($rule_name, {secret_question => 'dummy'}) },
        {error_code => 'NeedBothSecret'}, 'Secret question without answer will fail.';
};

subtest 'rule profile.valid_profile_countries' => sub {
    my $rule_name = 'profile.valid_profile_countries';

    lives_ok { $rule_engine->apply_rules($rule_name) } 'rule apples with empty args.';

    my %errors = (
        place_of_birth => 'InvalidPlaceOfBirth',
        citizen        => 'InvalidCitizenship',
        residence      => 'InvalidResidence'
    );
    for my $field (qw/place_of_birth citizen residence/) {
        lives_ok { $rule_engine->apply_rules($rule_name, {$field => 'id'}) } "Rule apples with a valid $field";

        is_deeply exception { $rule_engine->apply_rules($rule_name, {$field => 'xyz'}) },
            {error_code => $errors{$field}}, "Rule fails with an invalid $field";
    }
};

subtest 'rule profile.valid_promo_code' => sub {
    my $rule_name = 'profile.valid_promo_code';

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

    lives_ok { $rule_engine->apply_rules($rule_name) } 'rule apples with empty args.';
    lives_ok { $rule_engine->apply_rules($rule_name, {promo_code_status => 0}) } 'rule apples with false promo status.';
    lives_ok { $rule_engine->apply_rules($rule_name, {promo_code_status => 1, promo_code => 'abcd'}) }
    'rule apples if both promo code and status provided.';

    is_deeply exception { $rule_engine->apply_rules($rule_name, {promo_code_status => 1}) },
        {error_code => 'No promotion code was provided'}, 'rule fails if promo status is true, but promo code is missing.';

};

subtest 'rule profile.valid_non_pep_declaration_time' => sub {
    my $rule_name = 'profile.valid_non_pep_declaration_time';

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {error_code => 'InvalidNonPepTime'},
        'rule fails if non-pep declaraion is missing.';

    is_deeply exception { $rule_engine->apply_rules($rule_name, {non_pep_declaration_time => ''}) },
        {error_code => 'InvalidNonPepTime'}, 'rule fails if non-pep declaraion is false.';

    lives_ok { $rule_engine->apply_rules($rule_name, {non_pep_declaration_time => time}) } 'rule apples if declaration time equals to now.';
    is_deeply exception { $rule_engine->apply_rules($rule_name, {non_pep_declaration_time => time + 2}) },
        {error_code => 'TooLateNonPepTime'}, 'rule fails if non-pep declaraion is a future time.';
};

done_testing;
