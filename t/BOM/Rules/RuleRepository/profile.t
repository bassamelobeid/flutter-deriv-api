use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::AutoGenerated::Rose::Copier;
use BOM::Database::DataMapper::Copier;
use BOM::Database::Model::AccessToken;
use BOM::Rules::Engine;

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $user = BOM::User->create(
    email    => 'rules_profile@test.deriv',
    password => 'TEST PASS',
);
$user->add_client($client_cr);
my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

subtest 'rule profile.date_of_birth_complies_minimum_age' => sub {
    my $rule_name = 'profile.date_of_birth_complies_minimum_age';
    my $minimum_age;
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(minimum_age_for_country => sub { return $minimum_age });

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either residence or loginid is required/, 'Rersidence is required';

    my $args = {residence => 'af'};
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'InvalidDateOfBirth',
        rule       => $rule_name
        },
        'correct error when there is no date of birth in args';

    $args->{date_of_birth} = $client_cr->date_of_birth;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'InvalidResidence',
        rule       => $rule_name
        },
        'correct error when there is no minimum age configured';
    $minimum_age = 18;

    lives_ok { $rule_engine->apply_rules($rule_name, %$args) }
    'No error with valid args';

    $args->{date_of_birth} = 'abcd';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'InvalidDateOfBirth',
        rule       => $rule_name
        },
        'correct error for invalid date of birth';

    $args->{date_of_birth} = Date::Utility->new(time)->minus_time_interval('10y');
    $minimum_age = 10;
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'rule apples if date of birth matches the allowed minimum age';

    $args->{date_of_birth} = $args->{date_of_birth}->plus_time_interval('1d');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'BelowMinimumAge',
        rule       => $rule_name
        },
        'correct error when client is younger than minimum age';

    $mock_countries->unmock_all;
};

subtest 'rule profile.both_secret_question_and_answer_required' => sub {
    my $rule_name = 'profile.both_secret_question_and_answer_required';

    lives_ok { $rule_engine->apply_rules($rule_name) } 'rule apples with empty args.';

    is_deeply exception { $rule_engine->apply_rules($rule_name, secret_answer => 'dummy') },
        {
        error_code => 'NeedBothSecret',
        rule       => $rule_name
        },
        'Secret answer without question will fail.';

    is_deeply exception { $rule_engine->apply_rules($rule_name, secret_question => 'dummy') },
        {
        error_code => 'NeedBothSecret',
        rule       => $rule_name
        },
        'Secret question without answer will fail.';
};

subtest 'rule profile.valid_profile_countries' => sub {
    my $rule_name = 'profile.valid_profile_countries';

    lives_ok { $rule_engine->apply_rules($rule_name) } 'rule applies with empty args.';

    my %errors = (
        place_of_birth => 'InvalidPlaceOfBirth',
        citizen        => 'InvalidCitizenship',
        residence      => 'InvalidResidence'
    );
    for my $field (qw/place_of_birth citizen residence/) {
        lives_ok { $rule_engine->apply_rules($rule_name, $field => 'id') } "Rule apples with a valid $field";

        is_deeply exception { $rule_engine->apply_rules($rule_name, $field => 'xyz') },
            {
            error_code => $errors{$field},
            rule       => $rule_name
            },
            "Rule fails with an invalid $field";
    }
};

subtest 'rule profile.valid_promo_code' => sub {
    my $rule_name = 'profile.valid_promo_code';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'loginid is required';
    my $args = {loginid => $client_cr->loginid};
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'rule apples with empty args.';
    $args->{promo_code_status} = 0;
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'rule apples with false promo status.';

    $args->{promo_code_status} = 1;
    $args->{promo_code}        = 'abcd';
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) }
    'rule apples if both promo code and status provided.';

    delete $args->{promo_code};
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'No promotion code was provided',
        rule       => $rule_name
        },
        'rule fails if promo status is true, but promo code is missing.';

};

subtest 'rule profile.valid_non_pep_declaration_time' => sub {
    my $rule_name = 'profile.valid_non_pep_declaration_time';

    is_deeply exception { $rule_engine->apply_rules($rule_name) },
        {
        error_code => 'InvalidNonPepTime',
        rule       => $rule_name
        },
        'rule fails if non-pep declaraion is missing.';

    is_deeply exception { $rule_engine->apply_rules($rule_name, non_pep_declaration_time => '') },
        {
        error_code => 'InvalidNonPepTime',
        rule       => $rule_name
        },
        'rule fails if non-pep declaraion is false.';

    lives_ok { $rule_engine->apply_rules($rule_name, non_pep_declaration_time => time) } 'rule apples if declaration time equals to now.';
    is_deeply exception { $rule_engine->apply_rules($rule_name, non_pep_declaration_time => time + 2) },
        {
        error_code => 'TooLateNonPepTime',
        rule       => $rule_name
        },
        'rule fails if non-pep declaraion is a future time.';
};

my $rule_name = 'profile.residence_cannot_be_changed';
subtest $rule_name => sub {
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'loginid is required';
    my $args = {loginid => $client_cr->loginid};

    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rule applies with empty args';
    $args->{residence} = $client_cr->residence;
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rule applies with the same residence';

    $args->{residence} = 'us';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) }, {
        error_code => 'PerimissionDenied',

        rule => $rule_name
        },
        'rule fails with a different residence';

    $args->{residence} = undef;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'PerimissionDenied',
        rule       => $rule_name
        },
        'rule fails with empty residence';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(
        residence  => sub { return '' },
        is_virtual => sub { return 1 });
    $args->{residence} = 'us';
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rule applies for virtual client with empty residence';
    $mock_client->unmock_all;
};

$rule_name = 'profile.immutable_fields_cannot_change';
subtest $rule_name => sub {
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'loginid is required';
    my $args = {loginid => $client_cr->loginid};

    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rule applies with empty fields';

    $args = {
        loginid    => $client_cr->loginid,
        first_name => 'new name',
        last_name  => 'new last name'
    };
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'First name and last name are mutable in svg (the context landing company)';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(immutable_fields => sub { return qw/first_name citizen/; });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'ImmutableFieldChanged',
        details    => {field => 'first_name'},
        rule       => $rule_name
        },
        'Immitable fields cannot be changed';

    $mock_client->unmock_all;
};

$rule_name = 'profile.copier_cannot_allow_copiers';
subtest $rule_name => sub {
    my $mock_copier = Test::MockModule->new('BOM::Database::DataMapper::Copier');
    my $is_copier   = 1;
    $mock_copier->redefine(get_traders => sub { return $is_copier ? [1] : [] });

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'loginid is required';
    my $args = {loginid => $client_cr->loginid};

    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rule applies with no copier fields';

    $args->{allow_copiers} = 1;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'AllowCopiersError',
        rule       => $rule_name
        },
        'A copier cannot allow copiers';

    $is_copier = 0;
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'A trader can allow copiers';

    $mock_copier->unmock_all;
};

$rule_name = 'profile.tax_information_is_not_cleared';
subtest $rule_name => sub {
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'loginid is required';
    my $args = {loginid => $client_cr->loginid};
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rule applies with tax info';

    $client_cr->tax_identification_number('11111111');
    $client_cr->tax_residence('es');
    $client_cr->save;

    ok $client_cr->tax_identification_number, 'TIN is not clear';
    ok $client_cr->tax_residence,             'Tax residence is not clear';

    $args = {
        loginid                   => $client_cr->loginid,
        tax_identification_number => '1234',
        tax_residence             => 'tax_res'
    };
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Tax info can be edited';

    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, $_ => '') },
        {
            error_code => 'TaxInformationCleared',
            details    => {field => $_},
            rule       => $rule_name
        },
        "Tax info $_ cannot  be cleared"
    ) for (qw/tax_identification_number tax_residence/);

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(
        tax_identification_number => sub { return '' },
        tax_residence             => sub { return '' });

    $args = {
        loginid                   => $client_cr->loginid,
        tax_identification_number => '',
        tax_residence             => ''
    };
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Tax info can be cleared if they are already empty';

    $mock_client->unmock_all;
};

$rule_name = 'profile.tax_information_is_mandatory';
subtest $rule_name => sub {
    ok $client_cr->tax_identification_number, 'TIN is not clear';
    ok $client_cr->tax_residence,             'Tax residence is not clear';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'loginid is required';
    my $args = {loginid => $client_cr->loginid};

    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rule applies with empty tax info';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(
        tax_identification_number => sub { return undef; },
        tax_residence             => sub { return undef; });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'TINDetailsMandatory',
        rule       => $rule_name
        },
        "It fails when client's tax info is empty";

    for (qw/tax_identification_number tax_residence/) {
        is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, $_ => "some value") },
            {
            error_code => 'TINDetailsMandatory',
            rule       => $rule_name
            },
            'Both fields are required';
    }

    $args = {
        loginid                   => $client_cr->loginid,
        tax_identification_number => 'non-empty',
        tax_residence             => 'non-empty'
    };
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Applies for maltainvest with non-empty args';

    $mock_client->unmock_all;
};

$rule_name = 'profile.professional_request_allowed';
subtest $rule_name => sub {
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either landing_company or loginid is required/, 'loginid is required';
    my $args = {landing_company => 'svg'};

    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rule applies with no professional request';

    my $mock_landing_company = Test::MockModule->new('LandingCompany');
    $mock_landing_company->redefine(support_professional_client => sub { return 1; });

    $args->{request_professional_status} = 1;
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Professional client is supported by landing company';

    $mock_landing_company->redefine(support_professional_client => sub { return 0; });
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'ProfessionalNotAllowed',
        rule       => $rule_name
        },
        'Fails if professional client was not supported';

    $mock_landing_company->unmock_all;
};

$rule_name = 'profile.professional_request_is_not_resubmitted';
subtest $rule_name => sub {
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'loginid is required';
    my $args = {loginid => $client_cr->loginid};

    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rule applies with no proessional request';

    ok not($client_cr->status->professional or $client_cr->status->professional_requested), 'Professional is not set or requested';

    $args->{request_professional_status} = 1;
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'proessional status can be requested at this stage';

    $client_cr->status->set('professional_requested', 'test', 'test');
    $client_cr->save;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'ProfessionalAlreadySubmitted',
        rule       => $rule_name
        },
        'Fails if professional is requested';

    $client_cr->status->clear_professional_requested;
    $client_cr->status->set('professional', 'test', 'test');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'ProfessionalAlreadySubmitted',
        rule       => $rule_name
        },
        'Fails if client is professional';

    $client_cr->status->clear_professional;
};

done_testing;
