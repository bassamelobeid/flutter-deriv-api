use strict;
use warnings;
use utf8;

use Test::Most;
use Test::Fatal;

use JSON::MaybeUTF8 qw(:v1);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;
use BOM::Rules::RuleRepository::Onfido;
use BOM::User;

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    first_name  => 'elon',
    last_name   => 'musk'
});
my $user = BOM::User->create(
    email    => 'rules_onfido@test.deriv',
    password => 'TEST PASS',
);
$user->add_client($client_cr);
my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

subtest 'rule onfido.check_name_comparison' => sub {
    my $check_id  = 'test';
    my $rule_name = 'onfido.check_name_comparison';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Loginid is required';
    like exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid) }, qr/Onfido report is missing/,
        'Missing report from args';
    like exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, report => {}) }, qr/Onfido report api_name is invalid/,
        'Report api_name is not valid (should be document)';

    my $tests = [{
            properties => {
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
            properties => {
                first_name => 'ceo of dogecoin',
                last_name  => 'musk'
            },
            client => {
                first_name => 'elon',
                last_name  => 'musk'
            },
            error => 'NameMismatch'
        },
        {
            properties => {
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
            properties => {
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
            properties => {
                first_name => 'test de',
                last_name  => 'lima'
            },
            client => {
                first_name => 'test',
                last_name  => 'de lima'
            },
            error => undef,
        },
        {
            properties => {
                first_name => 'nino',
                last_name  => 'test'
            },
            client => {
                first_name => 'niño',
                last_name  => 'test'
            },
            error => undef
        },
        {
            properties => {
                first_name => 'aeioun AEIOUN',
                last_name  => 'aeiouc AEIOUC'
            },
            client => {
                first_name => 'áéíóúñ ÁÉÍÓÚÑ',
                last_name  => 'àèìòùç ÀÈÌÒÙÇ'
            },
            error => undef
        },
        {
            properties => {
                first_name => 'elon',
                last_name  => ''
            },
            client => {
                first_name => 'elon',
                last_name  => 'musk'
            },
            error => undef
        },
        {
            properties => {
                first_name => 'elon',
                last_name  => ''
            },
            client => {
                first_name => 'elon',
                last_name  => 'musk'
            },
            error => undef
        },
        {
            properties => {
                first_name => 'elon',
                last_name  => undef
            },
            client => {
                first_name => 'elon',
                last_name  => 'musk'
            },
            error => undef
        },
        {
            properties => {
                first_name => 'elon',
            },
            client => {
                first_name => 'elon',
                last_name  => 'musk'
            },
            error => undef
        },
        {
            properties => {
                first_name => 'elon',
                last_name  => 'NULL'
            },
            client => {
                first_name => 'elon',
                last_name  => 'musk'
            },
            error => undef
        },
        {
            properties => {
                first_name => 'elon musk',
                last_name  => ''
            },
            client => {
                first_name => 'elon',
                last_name  => 'ceo of dogecoin'
            },
            error => 'NameMismatch'
        },
        {
            properties => {
                first_name => 'A B',
                last_name  => 'C'
            },
            client => {
                first_name => 'B',
                last_name  => 'A'
            },
            error => 'NameMismatch'
        },
        {
            properties => {
                first_name => 'A B',
                last_name  => 'C'
            },
            client => {
                first_name => 'A',
                last_name  => 'C'
            },
            error => undef    # no error
        },
        {
            properties => {
                first_name => 'A',
                last_name  => 'A'
            },
            client => {
                first_name => 'A',
                last_name  => 'B'
            },
            error => 'NameMismatch'
        },
        {
            properties => {
                first_name => 'A',
                last_name  => 'A'
            },
            client => {
                first_name => 'B',
                last_name  => 'A'
            },
            error => 'NameMismatch'
        },
    ];

    for my $case ($tests->@*) {
        $client_cr->first_name($case->{client}->{first_name});
        $client_cr->last_name($case->{client}->{last_name});
        $client_cr->save;

        my %args = (
            loginid => $client_cr->loginid,
            report  => {
                api_name   => 'document',
                properties => encode_json_utf8($case->{properties}),
            });

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                {
                error_code => $error,
                rule       => $rule_name
                },
                "Broken rules: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are honored';
        }
    }
};

subtest 'rule onfido.check_dob_conformity' => sub {
    my $check_id  = 'test';
    my $rule_name = 'onfido.check_dob_conformity';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Loginid is required';
    like exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid) }, qr/Onfido report is missing/,
        'Missing report from args';
    like exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, report => {}) }, qr/Onfido report api_name is invalid/,
        'Report api_name is not valid (should be document)';

    my $tests = [{
            properties => {
                date_of_birth => '2020-10-10',
            },
            client => {
                date_of_birth => '2020-11-11',
            },
            error => 'DobMismatch'
        },
        {
            properties => {

            },
            client => {
                date_of_birth => '2020-11-11',
            },
            error => 'DobMismatch'
        },
        {
            properties => {date_of_birth => undef},
            client     => {
                date_of_birth => '2020-11-11',
            },
            error => 'DobMismatch'
        },
        {
            properties => {date_of_birth => '2020-11-11'},
            client     => {
                date_of_birth => undef,
            },
            error => 'DobMismatch'
        },
        {
            properties => {
                date_of_birth => '2020-11-11',
            },
            client => {
                date_of_birth => '2020-11-11',
            },
            error => undef
        },
    ];

    for my $case ($tests->@*) {
        $client_cr->date_of_birth($case->{client}->{date_of_birth});
        $client_cr->save;

        my %args = (
            loginid => $client_cr->loginid,
            report  => {
                api_name   => 'document',
                properties => encode_json_utf8($case->{properties}),
            });

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                {
                error_code => $error,
                rule       => $rule_name
                },
                "Broken rules: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are honored';
        }
    }
};

done_testing();
