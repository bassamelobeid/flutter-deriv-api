use strict;
use warnings;
use utf8;

use Test::Fatal qw( lives_ok exception );
use Test::More;
use Test::MockModule;

use JSON::MaybeUTF8 qw(:v1);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;
use BOM::Rules::RuleRepository::Onfido;
use BOM::User;

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    residence   => 'de',
});
my $user = BOM::User->create(
    email    => 'rules_idv@test.deriv',
    password => 'passwd',
);
$user->add_client($client_cr);

subtest 'rule idv.check_name_comparison' => sub {
    my $check_id    = 'test';
    my $rule_name   = 'idv.check_name_comparison';
    my $rule_engine = BOM::Rules::Engine->new(landing_company => 'svg');
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client is missing/, 'Client is required for this rule';

    $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name); $rule_engine->apply_rules($rule_name, {result => []}); }, qr/IDV result is missing/,
        'Missing result in passed args';

    my $tests = [{
            result => {
                first_name => 'elon',
                last_name  => 'ceo of dogecoin'
            },
            client => {
                first_name => 'elon',
                last_name  => 'musk'
            },
            error => 'NameMismatch'
        },
        {
            result => {full_name => 'ceo of dogecoin musk'},
            client => {
                first_name => 'elon',
                last_name  => 'musk'
            },
            error => 'NameMismatch'
        },
        {
            result => {
                first_name => 'elon',
                last_name  => 'musk'
            },
            client => {
                first_name => 'elon',
                last_name  => 'musk'
            },
            error => undef
        },
        {
            result => {
                first_name => 'nguyen',
                last_name  => 'long xuan'
            },
            client => {
                first_name => 'nguyen',
                last_name  => 'long'
            },
            error => undef
        },
        {
            result => {
                first_name => 'test de',
                last_name  => 'lima',
                full_name  => 'test de lima'
            },
            client => {
                first_name => 'test',
                last_name  => 'de lima'
            },
            error => undef
        },
        {
            result => {full_name => 'nino test'},
            client => {
                first_name => 'niño',
                last_name  => 'test'
            },
            error => undef
        },
        {
            result => {
                first_name => 'aeioun AEIOUN',
                last_name  => 'aeiouc AEIOUC'
            },
            client => {
                first_name => 'áéíóúñ ÁÉÍÓÚÑ',
                last_name  => 'àèìòùç ÀÈÌÒÙÇ'
            },
            error => undef
        }];

    for my $case ($tests->@*) {
        $client_cr->first_name($case->{client}->{first_name});
        $client_cr->last_name($case->{client}->{last_name});

        my $args = {result => $case->{result}};

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, $args) },
                {
                error_code => $error,
                },
                "Broken rules: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Rules are honored';
        }
    }
};

subtest 'rule idv.check_age_legality' => sub {
    my $check_id  = 'test';
    my $rule_name = 'idv.check_age_legality';

    my $rule_engine = BOM::Rules::Engine->new();
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client is missing/, 'Client is required';

    $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name); $rule_engine->apply_rules($rule_name, {result => []}); }, qr/IDV result is missing/,
        'Missing result in passed args';

    $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception {
        $rule_engine->apply_rules($rule_name, {result => {date_of_birth => ''}});
    }, qr/IDV date_of_birth is not present in result/, 'Missing date_of_birth in args';

    my $mock_country_config = Test::MockModule->new('Brands::Countries');
    $mock_country_config->mock(
        minimum_age_for_country => sub {
            my (undef, $country) = @_;

            return 18 if $country eq 'de';
            return 25 if $country eq 'ir';
        });

    my $tests = [{
            result => {
                date_of_birth => Date::Utility->new->date_ddmmyyyy,
            },
            client => {
                residence => 'de',
            },
            error => 'UnderAge'
        },
        {
            result => {

                date_of_birth => Date::Utility->new->_minus_years(19),
            },
            client => {
                residence => 'de',
            },
            error => undef
        },
        {
            result => {

                date_of_birth => Date::Utility->new,
            },
            client => {
                residence => 'ir',
            },
            error => 'UnderAge'
        },
        {
            result => {

                date_of_birth => Date::Utility->new->_minus_years(25),
            },
            client => {
                residence => 'ir',
            },
            error => 'UnderAge'
        },
        {
            result => {

                date_of_birth => Date::Utility->new->_minus_years(25)->_minus_months(1),
            },
            client => {
                residence => 'ir',
            },
            error => undef
        },
        {
            result => {

                date_of_birth => Date::Utility->new->_minus_years(60),
            },
            client => {
                residence => 'ir',
            },
            error => undef
        }];

    for my $case ($tests->@*) {
        $client_cr->residence($case->{client}->{residence});

        $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

        my $args = {result => $case->{result}};

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, $args) }, +{error_code => $error}, "Broken rules: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Rules are honored';
        }
    }

    $mock_country_config->unmock_all();
};

done_testing();
