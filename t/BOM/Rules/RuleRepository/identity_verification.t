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
    my $rule_name = 'idv.check_expiration_date';

    my $rule_engine = BOM::Rules::Engine->new();

    is_deeply exception { $rule_engine->apply_rules($rule_name) },
        {
        error_code => "IDVResultMissing",
        rule       => $rule_name
        },
        "Missing result in passed args";

    is_deeply exception { $rule_engine->apply_rules($rule_name, result => {}); },
        {
        error_code => "DocumentMissing",
        rule       => $rule_name
        },
        "Missing document in passed args";

    my $is_lifetime_valid   = 0;
    my $mock_country_config = Test::MockModule->new('Brands::Countries');
    $mock_country_config->mock(
        get_idv_config => sub {
            return {document_types => {test => {lifetime_valid => $is_lifetime_valid}}};
        });

    my $tests = [{
            idv    => {lifetime_valid => 1},
            result => {
                expiry_date => 'Not Available',
            },
            error => undef,
        },
        {
            idv    => {lifetime_valid => 0},
            result => {
                expiry_date => undef,
            },
            error => 'Expired',
        },
        {
            idv    => {lifetime_valid => 0},
            result => {
                expiry_date => Date::Utility->new->_plus_months(1)->date_ddmmyyyy,
            },
            error => undef,
        },
        {
            idv    => {lifetime_valid => 1},
            result => {
                expiry_date => Date::Utility->new->_minus_months(1)->date_ddmmyyyy,
            },
            error => undef
        },
        {
            idv    => {lifetime_valid => 0},
            result => {
                expiry_date => Date::Utility->new->_minus_months(1)->date_ddmmyyyy,
            },
            error => 'Expired'
        },
        {
            idv    => {lifetime_valid => 0},
            result => {
                expiry_date => Date::Utility->new->today,
            },
            error => 'Expired'
        },
        {
            idv    => {lifetime_valid => 0},
            result => {
                expiry_date => '1999/02/66',
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
                "Violated rule: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are passed';
        }
    }
};

subtest 'rule idv.check_name_comparison' => sub {
    my $check_id    = 'test';
    my $rule_name   = 'idv.check_name_comparison';
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid); },
        {
        error_code => "IDVResultMissing",
        rule       => $rule_name
        },
        "Missing result in passed args";

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, result => []); },
        {
        error_code => "IDVResultMissing",
        rule       => $rule_name
        },
        "Missing result in passed args";

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
                "Violated rule: $error";
        } else {
            $rule_engine->apply_rules($rule_name, %args);
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are passed';
        }
    }
};

subtest 'rule idv.check_age_legality' => sub {
    my $rule_name = 'idv.check_age_legality';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required';

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, result => []); },
        {
        error_code => "IDVResultMissing",
        rule       => $rule_name
        },
        "Missing result in passed args";

    my $mock_country_config = Test::MockModule->new('Brands::Countries');
    $mock_country_config->mock(
        minimum_age_for_country => sub {
            my (undef, $country) = @_;

            return 18 if $country eq 'de';
            return 25 if $country eq 'ir';
        });

    my $tests = [{
            result => {
                birthdate => undef,
            },
            client => {
                residence => 'de',
            },
            error => undef
        },
        {
            result => {
                birthdate => Date::Utility->new->date_ddmmyyyy,
            },
            client => {
                residence => 'de',
            },
            error => 'UnderAge'
        },
        {
            result => {
                birthdate => Date::Utility->new->_minus_years(19),
            },
            client => {
                residence => 'de',
            },
            error => undef
        },
        {
            result => {
                birthdate => Date::Utility->new,
            },
            client => {
                residence => 'ir',
            },
            error => 'UnderAge'
        },
        {
            result => {
                birthdate => Date::Utility->new->_minus_years(25),
            },
            client => {
                residence => 'ir',
            },
            error => 'UnderAge'
        },
        {
            result => {
                birthdate => Date::Utility->new->_minus_years(25)->_minus_months(1),
            },
            client => {
                residence => 'ir',
            },
            error => undef
        },
        {
            result => {
                birthdate => Date::Utility->new->_minus_years(60),
            },
            client => {
                residence => 'ir',
            },
            error => undef
        },
        {
            result => {
                birthdate => '',
            },
            client => {
                residence => 'be',
            },
            error => undef
        },
        {
            result => {
                birthdate => 'Not Available',
            },
            client => {
                residence => 'be',
            },
            error => undef
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
                "Violated rule: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are passed';
        }
    }

    $mock_country_config->unmock_all();
};

subtest 'rule idv.check_dob_conformity' => sub {
    my $rule_name = 'idv.check_dob_conformity';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required';

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, result => []); },
        {
        error_code => "IDVResultMissing",
        rule       => $rule_name
        },
        "Missing result in passed args";

    my $tests = [{
            result => {
                birthdate => Date::Utility->new->date_yyyymmdd,
            },
            client => {
                birthdate => Date::Utility->new->_minus_months(1)->date_yyyymmdd,
            },
            error => 'DobMismatch'
        },
        {
            result => {
                birthdate => Date::Utility->new->date_yyyymmdd,
            },
            client => {
                birthdate => Date::Utility->new->date_yyyymmdd,
            },
            error => undef
        },
        {
            result => {
                birthdate => Date::Utility->new->date_ddmmyyyy,
            },
            client => {
                birthdate => Date::Utility->new->date_yyyymmdd,
            },
            error => undef
        },
        {
            result => {
                birthdate => Date::Utility->new->datetime_yyyymmdd_hhmmss,
            },
            client => {
                birthdate => Date::Utility->new->date_yyyymmdd,
            },
            error => 'DobMismatch'
        },
        {
            result => {
                birthdate => Date::Utility->new->date_ddmmyyyy,
            },
            client => {
                birthdate => '1999-10-31',
            },
            error => 'DobMismatch'
        },
        {
            result => {
                birthdate => undef,
            },
            client => {
                birthdate => Date::Utility->new->date_yyyymmdd,
            },
            error => 'DobMismatch'
        },
        {
            result => {
                birthdate => '2020-02-02',
            },
            client => {
                birthdate => '2020-02-01',
            },
            error => 'DobMismatch'
        },
        {
            result => {
                birthdate => 'Not Available',
            },
            client => {
                birthdate => '123',
            },
            error => 'DobMismatch'
        },
    ];

    for my $case ($tests->@*) {
        $client_cr->date_of_birth($case->{client}->{birthdate});

        my %args = (
            loginid => $client_cr->loginid,
            result  => $case->{result});

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                +{
                error_code => $error,
                rule       => $rule_name
                },
                "Violated rule: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are passed';
        }
    }
};

subtest 'rule idv.check_verification_necessity' => sub {
    my $rule_name = 'idv.check_verification_necessity';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    my $mock_client_status        = Test::MockModule->new('BOM::User::Client::Status');
    my $mock_identityverification = Test::MockModule->new('BOM::User::IdentityVerification');

    my $testCases = [{
            client         => {statuses => ['allow_document_upload',]},
            idv_disallowed => 0,
            error          => undef,
        },
        {
            client         => {statuses => ['allow_document_upload',]},
            idv_disallowed => 1,
            error          => 'IdentityVerificationDisallowed',
        },
        {
            client         => {statuses => ['allow_document_upload', 'age_verification']},
            idv_disallowed => 0,
            error          => 'AlreadyAgeVerified',
        },
        {
            client                      => {statuses => ['allow_document_upload', 'age_verification']},
            idv_disallowed              => 0,
            error                       => undef,
            idv_status                  => 'expired',
            has_expired_document_chance => 1,
        },
        {
            client                      => {statuses => ['allow_document_upload', 'age_verification']},
            idv_disallowed              => 0,
            error                       => 'AlreadyAgeVerified',
            idv_status                  => 'expired',
            has_expired_document_chance => 0,
        },
    ];

    for my $case ($testCases->@*) {
        for my $status ($case->{client}->{statuses}->@*) {
            $mock_client_status->mock($status => 1);
        }

        $mock_identityverification->mock('is_idv_disallowed'           => $case->{idv_disallowed});
        $mock_identityverification->mock('status'                      => $case->{idv_status} // 'none');
        $mock_identityverification->mock('has_expired_document_chance' => $case->{has_expired_document_chance});

        my %args = (loginid => $client_cr->loginid);

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                +{
                error_code => $error,
                rule       => $rule_name
                },
                "Violated rule: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are passed';
        }

        $mock_client_status->unmock_all();
        $mock_identityverification->unmock_all();
    }
};

subtest 'rule idv.check_service_availibility' => sub {
    my $rule_name = 'idv.check_service_availibility';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid) },
        {
        error_code => "IssuingCountryMissing",
        rule       => $rule_name
        },
        "document issuing_country is required for this rule";

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, issuing_country => 'xx') },
        {
        error_code => "DocumentTypeMissing",
        rule       => $rule_name
        },
        "document_type is required for this rule'";

    my $mock_country_config   = Test::MockModule->new('Brands::Countries');
    my $mock_platform_utility = Test::MockModule->new('BOM::Platform::Utility');
    my $mock_idv_model        = Test::MockModule->new('BOM::User::IdentityVerification');
    my $mock_qa               = Test::MockModule->new('BOM::Config');

    my $test_cases = [{
            input => {
                issuing_country => 'ir',
                type            => 'passport',
            },
            idv_submission_left => 1,
            has_idv             => 1,
            idv_config          => {document_types => {passport => 1}},
            error               => undef,
        },
        {
            input => {
                issuing_country => 'wrong country',
                type            => 'birth_cert',
            },
            idv_submission_left => 1,
            has_idv             => 1,
            idv_config          => undef,
            error               => 'NotSupportedCountry',
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
            },
            idv_submission_left => 1,
            has_idv             => 0,
            idv_config          => {},
            error               => 'IdentityVerificationDisabled',
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
            },
            idv_submission_left => 0,
            has_idv             => 1,
            idv_config          => {},
            error               => 'NoSubmissionLeft',
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
            },
            idv_submission_left         => 0,
            has_idv                     => 1,
            idv_config                  => {document_types => {passport => 1}},
            error                       => undef,
            idv_status                  => 'expired',
            has_expired_document_chance => 1,
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
            },
            idv_submission_left         => 0,
            has_idv                     => 1,
            idv_config                  => {document_types => {passport => 1}},
            error                       => 'NoSubmissionLeft',
            idv_status                  => 'expired',
            has_expired_document_chance => 0,
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'birth_cert',
            },
            idv_submission_left => 1,
            has_idv             => 1,
            idv_config          => {document_types => {passport => 1}},
            error               => 'InvalidDocumentType',
        },
        {
            input => {
                issuing_country => 'qq',
                type            => 'passport',
            },
            idv_submission_left => 1,
            has_idv             => 0,
            idv_config          => undef,
            error               => undef,
            on_qa               => 1,
        },
        {
            input => {
                issuing_country => 'qq',
                type            => 'passport',
            },
            idv_submission_left => 1,
            has_idv             => 0,
            idv_config          => undef,
            error               => 'NotSupportedCountry',
            on_qa               => 0,
        },
        {
            input => {
                issuing_country => 'wrong country',
                type            => 'passport',
            },
            idv_submission_left => 1,
            has_idv             => 0,
            idv_config          => undef,
            error               => 'NotSupportedCountry',
            on_qa               => 1,
        },
    ];

    for my $case ($test_cases->@*) {
        $mock_platform_utility->mock('has_idv' => $case->{has_idv});
        $mock_country_config->mock('get_idv_config' => $case->{idv_config});
        $mock_country_config->mock(
            'is_idv_supported',
            sub {
                my (undef, $country) = @_;

                return 1 if $country eq 'ir';

                return 0;
            });
        $mock_idv_model->mock('submissions_left' => $case->{idv_submission_left});
        $mock_idv_model->mock('status'           => $case->{idv_status} // 'none');
        $mock_idv_model->mock('has_expired_document_chance', $case->{has_expired_document_chance});
        $mock_qa->mock('on_qa' => $case->{on_qa});

        my %args = (
            loginid         => $client_cr->loginid,
            issuing_country => $case->{input}->{issuing_country},
            document_type   => $case->{input}->{type},
        );

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                +{
                error_code => $error,
                rule       => $rule_name
                },
                "Violated rule: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are passed';
        }

        $mock_platform_utility->unmock_all();
        $mock_country_config->unmock_all();
        $mock_idv_model->unmock_all();
        $mock_qa->unmock_all();
    }
};

subtest 'rule idv.valid_document_number' => sub {
    my $rule_name = 'idv.valid_document_number';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

    is_deeply exception { $rule_engine->apply_rules($rule_name) },
        {
        error_code => "IssuingCountryMissing",
        rule       => $rule_name
        },
        "document issuing_country is required for this rule";

    is_deeply exception { $rule_engine->apply_rules($rule_name, issuing_country => 'xx') },
        {
        error_code => "DocumentTypeMissing",
        rule       => $rule_name
        },
        "document_type is required for this rule'";

    is_deeply exception { $rule_engine->apply_rules($rule_name, issuing_country => 'xx', document_type => 'national_id') },
        {
        error_code => "DocumentNumberMissing",
        rule       => $rule_name
        },
        "document_number is required for this rule'";

    my $mock_country_config = Test::MockModule->new('Brands::Countries');
    my $mock_qa             = Test::MockModule->new('BOM::Config');

    my $test_cases = [{
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            idv_config => {document_types => {passport => {format => '^E'}}},
            error      => undef,
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            idv_config => {document_types => {passport => {format => 'E$'}}},
            error      => 'InvalidDocumentNumber',
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            idv_config => {
                document_types => {
                    passport => {
                        format     => '^E',
                        additional => {format => '^A'}}}
            },
            error => 'InvalidDocumentAdditional',
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => '123E',
                additional      => 'E11'
            },
            idv_config => {
                document_types => {
                    passport => {
                        format     => 'E$',
                        additional => {format => '^A'}}}
            },
            error => 'InvalidDocumentAdditional',
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => '123E',
                additional      => 'A11'
            },
            idv_config => {
                document_types => {
                    passport => {
                        format     => 'E$',
                        additional => {format => '^A'}}}
            },
            error => undef,
        },
        {
            input => {
                issuing_country => 'qq',
                type            => 'passport',
                number          => 'E123'
            },
            idv_config => {document_types => {passport => {format => '^E'}}},
            error      => undef,
            on_qa      => 1,
        },
        {
            input => {
                issuing_country => 'qq',
                type            => 'passport',
                number          => 'E123'
            },
            idv_config => {document_types => {passport => {format => 'E$'}}},
            error      => 'InvalidDocumentNumber',
            on_qa      => 0,
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            idv_config => {document_types => {passport => {format => 'E$'}}},
            error      => 'InvalidDocumentNumber',
            on_qa      => 1,
        },
    ];

    for my $case ($test_cases->@*) {
        $mock_country_config->mock('get_idv_config' => $case->{idv_config});
        $mock_qa->mock('on_qa' => $case->{on_qa});

        my %args = (
            issuing_country     => $case->{input}->{issuing_country},
            document_type       => $case->{input}->{type},
            document_number     => $case->{input}->{number},
            document_additional => $case->{input}->{additional});

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                +{
                error_code => $error,
                rule       => $rule_name
                },
                "Violated rule: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are passed';
        }

        $mock_country_config->unmock_all();
        $mock_qa->unmock_all();
    }
};

subtest 'rule idv.check_document_acceptability' => sub {
    my $rule_name = 'idv.check_document_acceptability';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid) },
        {
        error_code => "IssuingCountryMissing",
        rule       => $rule_name
        },
        "document issuing_country is required for this rule";

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, issuing_country => 'xx') },
        {
        error_code => "DocumentTypeMissing",
        rule       => $rule_name
        },
        "document_type is required for this rule'";

    is_deeply
        exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, issuing_country => 'xx', document_type => 'national_id') },
        {
        error_code => "DocumentNumberMissing",
        rule       => $rule_name
        },
        "document_number is required for this rule'";

    my $mock_idv_model = Test::MockModule->new('BOM::User::IdentityVerification');
    my $mock_qa        = Test::MockModule->new('BOM::Config');

    my $test_cases = [{
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            claimed_docs => undef,
            error        => undef,
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            claimed_docs => [],
            error        => undef,
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            claimed_docs => [{
                    status          => 'refuted',
                    expiration_date => Date::Utility->new->plus_years(1)->date_yyyymmdd,
                },
                {
                    status          => 'failed',
                    expiration_date => Date::Utility->new->plus_years(1)->date_yyyymmdd,
                },
                {status => 'failed'},
                {status => 'refuted'},
            ],
            error => undef,
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            claimed_docs => [{status => 'x'}],
            error        => undef,
        },
        {
            input => {
                issuing_country => 'qq',
                type            => 'passport',
                number          => 'E123'
            },
            claimed_docs => [{status => 'pending'},],
            error        => undef,
            on_qa        => 1,
        },
        {
            input => {
                issuing_country => 'qq',
                type            => 'passport',
                number          => 'E123'
            },
            claimed_docs => [{status => 'verified'},],
            error        => undef,
            on_qa        => 1,
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            claimed_docs => [{status => 'pending'},],
            error        => 'ClaimedDocument',
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            claimed_docs => [{status => 'verified'},],
            error        => 'ClaimedDocument',
        },
        {
            input => {
                issuing_country => 'ir',
                type            => 'passport',
                number          => 'E123'
            },
            claimed_docs     => [{status => 'verified'},],
            underage_blocked => 1,
            error            => 'UnderageBlocked',
            on_qa            => 1,
            error_params     => {
                underage_user_id => 1,
            }
        },
        {
            input => {
                issuing_country => 'qq',
                type            => 'passport',
                number          => 'E123'
            },
            claimed_docs     => [{status => 'verified'},],
            underage_blocked => 1,
            error            => 'UnderageBlocked',
            error_params     => {
                underage_user_id => 1,
            }
        },
    ];

    for my $case ($test_cases->@*) {
        $mock_idv_model->mock('get_claimed_documents' => $case->{claimed_docs});
        $mock_idv_model->mock('is_underage_blocked'   => $case->{underage_blocked});
        $mock_qa->mock('on_qa' => $case->{on_qa});

        my %args = (
            loginid         => $client_cr->loginid,
            issuing_country => $case->{input}->{issuing_country},
            document_type   => $case->{input}->{type},
            document_number => $case->{input}->{number});

        if (my $error = $case->{error}) {
            my $params = $case->{error_params};
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                +{
                error_code => $error,
                rule       => $rule_name,
                $params ? (params => $params) : (),
                },
                "Violated rule: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are passed';
        }

        $mock_idv_model->unmock_all();
        $mock_qa->unmock_all();
    }
};

subtest 'rule idv.check_opt_out_availability' => sub {
    my $rule_name = 'idv.check_opt_out_availability';

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid) },
        {
        error_code => "IssuingCountryMissing",
        rule       => $rule_name
        },
        "document issuing_country is required for this rule";

    my $mock_country_config = Test::MockModule->new('Brands::Countries');
    my $mock_idv_model      = Test::MockModule->new('BOM::User::IdentityVerification');
    my $mock_qa             = Test::MockModule->new('BOM::Config');

    my $test_cases = [{
            input               => {issuing_country => 'ir'},
            idv_submission_left => 1,
            error               => undef,
        },
        {
            input               => {issuing_country => 'wrong country'},
            idv_submission_left => 1,
            error               => 'NotSupportedCountry',
        },
        {
            input               => {issuing_country => 'ir'},
            idv_submission_left => 0,
            error               => 'NoSubmissionLeft',
        },
        {
            input               => {issuing_country => 'qq'},
            idv_submission_left => 1,
            error               => undef,
            on_qa               => 1,
        },
        {
            input               => {issuing_country => 'qq'},
            idv_submission_left => 1,
            error               => 'NotSupportedCountry',
            on_qa               => 0,
        },
        {
            input               => {issuing_country => 'wrong country'},
            idv_submission_left => 1,
            has_idv             => 0,
            error               => 'NotSupportedCountry',
            on_qa               => 1,
        },
        {
            input                       => {issuing_country => 'ir'},
            idv_submission_left         => 0,
            has_idv                     => 1,
            error                       => undef,
            idv_status                  => 'expired',
            has_expired_document_chance => 1,
        },
        {
            input                       => {issuing_country => 'ir'},
            idv_submission_left         => 0,
            has_idv                     => 1,
            error                       => 'NoSubmissionLeft',
            idv_status                  => 'expired',
            has_expired_document_chance => 0,
        },
    ];

    for my $case ($test_cases->@*) {
        $mock_country_config->mock(
            'is_idv_supported',
            sub {
                my (undef, $country) = @_;

                return 1 if $country eq 'ir';

                return 0;
            });

        $mock_idv_model->mock('submissions_left' => $case->{idv_submission_left});
        $mock_idv_model->mock('status'           => $case->{idv_status} // 'none');
        $mock_idv_model->mock('has_expired_document_chance', $case->{has_expired_document_chance});
        $mock_qa->mock('on_qa' => $case->{on_qa});

        my %args = (
            loginid         => $client_cr->loginid,
            issuing_country => $case->{input}->{issuing_country});

        if (my $error = $case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                +{
                error_code => $error,
                rule       => $rule_name
                },
                "Violated rule: $error";
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rules are passed';
        }

        $mock_country_config->unmock_all();
        $mock_idv_model->unmock_all();
        $mock_qa->unmock_all();
    }
};

done_testing();
