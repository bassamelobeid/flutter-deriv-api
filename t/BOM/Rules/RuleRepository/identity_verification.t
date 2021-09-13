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

subtest 'rule idv.check_expiration_date' => sub {
    my $check_id  = 'test';
    my $rule_name = 'idv.check_expiration_date';

    my $rule_engine = BOM::Rules::Engine->new();

    like exception { $rule_engine->apply_rules($rule_name); }, qr/IDV result is missing/, 'Missing result in passed args';
    like exception { $rule_engine->apply_rules($rule_name, result => {}); }, qr/document is missing/, 'Missing document in passed args';

    my $mock_country_config = Test::MockModule->new('Brands::Countries');
    my $is_lifetime_valid   = 0;
    $mock_country_config->mock(
        get_idv_config => sub {
            return {document_types => {test => {lifetime_valid => $is_lifetime_valid}}};
        });

    my $tests = [{
            idv    => {lifetime_valid => 1},
            result => {
                expiration_date => 'Not Available',
            },
            error => undef,
        },
        {
            idv    => {lifetime_valid => 0},
            result => {
                expiration_date => undef,
            },
            error => 'Expired',
        },
        {
            idv    => {lifetime_valid => 0},
            result => {
                expiration_date => Date::Utility->new->_plus_months(1)->date_ddmmyyyy,
            },
            error => undef,
        },
        {
            idv    => {lifetime_valid => 1},
            result => {
                expiration_date => Date::Utility->new->_minus_months(1)->date_ddmmyyyy,
            },
            error => undef
        },
        {
            idv    => {lifetime_valid => 0},
            result => {
                expiration_date => Date::Utility->new->_minus_months(1)->date_ddmmyyyy,
            },
            error => 'Expired'
        },
        {
            idv    => {lifetime_valid => 0},
            result => {
                expiration_date => Date::Utility->new->today,
            },
            error => 'Expired'
        },
        {
            idv    => {lifetime_valid => 0},
            result => {
                expiration_date => '1999/02/66',
            },
            error => 'Expired'
        },
    ];

    for my $case ($tests->@*) {
        $is_lifetime_valid = $case->{idv}->{lifetime_valid};

        my %args = (
            result   => $case->{result},
            document => {
                document_type   => 'test',
                issuing_country => 'test'
            });

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                +{
                error_code => $error,
                rule       => $rule_name
                },
                "Broken rules: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are honored';
        }
    }
};

subtest 'rule idv.check_name_comparison' => sub {
    my $check_id    = 'test';
    my $rule_name   = 'idv.check_name_comparison';
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    like exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid); }, qr/IDV result is missing/,
        'Missing result in passed args';
    like exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, result => []); }, qr/IDV result is missing/,
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
        $client_cr->save;

        my %args = (
            loginid => $client_cr->loginid,
            result  => $case->{result});

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                {
                error_code => $error,
                rule       => $rule_name
                },
                "Broken rules: $error";
        } else {
            $rule_engine->apply_rules($rule_name, %args);
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are honored';
        }
    }
};

subtest 'rule idv.check_age_legality' => sub {
    my $check_id  = 'test';
    my $rule_name = 'idv.check_age_legality';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required';

    like exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, result => []); }, qr/IDV result is missing/,
        'Missing result in passed args';

    $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

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
        },
        {
            result => {

                date_of_birth => '',
            },
            client => {
                residence => 'be',
            },
            error => 'UnderAge'
        },
        {
            result => {

                date_of_birth => 'Not Available',
            },
            client => {
                residence => 'be',
            },
            error => 'UnderAge'
        },
    ];

    for my $case ($tests->@*) {
        $client_cr->residence($case->{client}->{residence});
        $client_cr->save;

        my %args = (
            loginid => $client_cr->loginid,
            result  => $case->{result});

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                +{
                error_code => $error,
                rule       => $rule_name
                },
                "Broken rules: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are honored';
        }
    }

    $mock_country_config->unmock_all();
};

subtest 'rule idv.check_dob_conformity' => sub {
    my $check_id  = 'test';
    my $rule_name = 'idv.check_dob_conformity';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required';

    like exception {
        $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid);
        $rule_engine->apply_rules(
            $rule_name,
            loginid => $client_cr->loginid,
            result  => []);
    }, qr/IDV result is missing/, 'Missing result in passed args';

    my $tests = [{
            result => {
                date_of_birth => Date::Utility->new->date_yyyymmdd,
            },
            client => {
                date_of_birth => Date::Utility->new->_minus_months(1)->date_yyyymmdd,
            },
            error => 'DobMismatch'
        },
        {
            result => {
                date_of_birth => Date::Utility->new->date_yyyymmdd,
            },
            client => {
                date_of_birth => Date::Utility->new->date_yyyymmdd,
            },
            error => undef
        },
        {
            result => {
                date_of_birth => Date::Utility->new->date_ddmmyyyy,
            },
            client => {
                date_of_birth => Date::Utility->new->date_yyyymmdd,
            },
            error => undef
        },
        {
            result => {
                date_of_birth => Date::Utility->new->datetime_yyyymmdd_hhmmss,
            },
            client => {
                date_of_birth => Date::Utility->new->date_yyyymmdd,
            },
            error => 'DobMismatch'
        },
        {
            result => {
                date_of_birth => Date::Utility->new->date_ddmmyyyy,
            },
            client => {
                date_of_birth => '1999-10-31',
            },
            error => 'DobMismatch'
        },
        {
            result => {
                date_of_birth => undef,
            },
            client => {
                date_of_birth => Date::Utility->new->date_yyyymmdd,
            },
            error => 'DobMismatch'
        },
        {
            result => {
                date_of_birth => '2020-02-02',
            },
            client => {
                date_of_birth => '2020-02-01',
            },
            error => 'DobMismatch'
        },
        {
            result => {
                date_of_birth => 'Not Available',
            },
            client => {
                date_of_birth => '123',
            },
            error => 'DobMismatch'
        },
    ];

    for my $case ($tests->@*) {
        $client_cr->date_of_birth($case->{client}->{date_of_birth});

        my $args = {
            loginid => $client_cr->loginid,
            result  => $case->{result}};

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
                +{
                error_code => $error,
                rule       => $rule_name
                },
                "Broken rules: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Rules are honored';
        }
    }
};

done_testing();
