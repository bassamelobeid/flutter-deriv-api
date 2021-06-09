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

subtest 'rule onfido.check_name_comparison' => sub {
    my $check_id    = 'test';
    my $rule_name   = 'onfido.check_name_comparison';
    my $rule_engine = BOM::Rules::Engine->new(landing_company => 'svg');
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client is missing/, 'Client is required for this rule';

    $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Onfido report is missing/, 'Missing report from args';
    like exception { $rule_engine->apply_rules($rule_name, {report => {}}) }, qr/Onfido report api_name is invalid/,
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
            error => undef
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
        }];

    for my $case ($tests->@*) {
        $client_cr->first_name($case->{client}->{first_name});
        $client_cr->last_name($case->{client}->{last_name});

        my $args = {
            report => {
                api_name   => 'document',
                properties => encode_json_utf8($case->{properties}),
            }};

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, $args) },
                {
                code => $error,
                },
                "Broken rules: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Rules are honored';
        }
    }
};

done_testing();
