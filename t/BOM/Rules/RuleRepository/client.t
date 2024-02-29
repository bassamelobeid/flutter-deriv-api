use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;
use BOM::Test::Helper::Client;
use BOM::Rules::Engine;
use BOM::User::Client;
use JSON::MaybeUTF8 qw(encode_json_utf8);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
my $user = BOM::User->create(
    email          => 'rule_client@binary.com',
    password       => 'abcd',
    email_verified => 1,
);
$user->add_client($client);
$user->add_client($client_vr);
$user->add_client($client_mf);

subtest 'rule profile.address_postcode_mandatory' => sub {
    my $rule_name   = 'profile.address_postcode_mandatory';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    my %args = (loginid => $client->loginid);
    $client->address_postcode('');
    $client->save;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'PostcodeRequired',
        rule       => $rule_name
        },
        'correct error when postcode is missing';

    $args{address_postcode} = '123';
    ok $rule_engine->apply_rules($rule_name, %args), 'Test passes with a postcode in args';

    delete $args{address_postcode};
    $client->address_postcode('345');
    $client->save;
    ok $rule_engine->apply_rules($rule_name, %args), 'Test passes with non-empty postcode';
};

subtest 'rule profile.no_pobox_in_address' => sub {
    my $rule_name   = 'profile.no_pobox_in_address';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    for my $arg (qw/address_line_1 address_line_2/) {
        for my $value ('p.o. box', 'p o. box', 'p o box', 'P.O Box', 'Po. BOX') {
            is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $client->loginid, $arg => $value) },
                {
                error_code => 'PoBoxInAddress',
                rule       => $rule_name
                },
                "$value is rejected";
        }
    }

    my %args = (loginid => $client->loginid);
    ok $rule_engine->apply_rules($rule_name, %args, address_line_1 => 'There is no pobox here'), 'It passes with a slight change in spelling';
    ok $rule_engine->apply_rules($rule_name, %args), 'Missing address in args is accepted';
};

subtest 'rule client.check_duplicate_account' => sub {
    my $rule_name   = 'client.check_duplicate_account';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(check_duplicate_account => sub { return 1 });

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    my %args = (loginid => $client->loginid);
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'DuplicateAccount',
        rule        => $rule_name,
        description => 'Duplicate account found'
        },
        "Duplicate accounnt is rejected";
    $mock_client->redefine(check_duplicate_account => sub { return 0 });
    ok $rule_engine->apply_rules($rule_name, %args), 'Non-duplicate account is accepted';

    $mock_client->unmock_all;
};

subtest 'rule client.has_currency_set' => sub {
    my $rule_name   = 'client.has_currency_set';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';

    my %args = (loginid => $client->loginid);
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'SetExistingAccountCurrency',
        rule       => $rule_name,
        params     => [$client->loginid],
        },
        'correct error when currency is missing';

    $client->set_default_account('USD');
    ok $rule_engine->apply_rules($rule_name, %args), 'Test passes when currency is set';
};

subtest 'rule client.residence_is_not_empty' => sub {
    my $rule_name   = 'client.residence_is_not_empty';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';
    my %args = (loginid => $client->loginid);

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    my $residence   = 'id';
    $mock_client->redefine(residence => sub { return $residence });

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies when residence is set.';

    $residence = undef;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'NoResidence',
        rule        => $rule_name,
        description => 'Residence information for the client is missing'
        },
        'Rule fails when residence is empty';

    $mock_client->unmock_all;
};

subtest 'rule client.signup_immutable_fields_not_changed' => sub {
    my $rule_name      = 'client.signup_immutable_fields_not_changed';
    my $rule_engine    = BOM::Rules::Engine->new(client => $client);
    my $rule_engine_vr = BOM::Rules::Engine->new(client => $client_vr);

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';
    my %args = (loginid => $client->loginid);

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies with no fields.';

    for my $field (qw/citizen place_of_birth residence/) {
        $args{loginid} = $client->loginid;
        $client->status->clear_duplicate_account;
        $client->status->_build_all;
        $client->$field('asdf');
        $client->save;

        is_deeply exception { $rule_engine->apply_rules($rule_name, %args, $field => 'xyz') },
            {
            error_code  => 'CannotChangeAccountDetails',
            details     => {changed => [$field]},
            rule        => $rule_name,
            description => "$field field(s) are modified"
            },
            "Rule fails when empty immutable field $field is different";

        $client->$field('af');
        $client->save;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args, $field => 'xyz') },
            {
            error_code  => 'CannotChangeAccountDetails',
            details     => {changed => [$field]},
            rule        => $rule_name,
            description => "$field field(s) are modified"
            },
            "Rule fails when non-empty immutable field $field is different";

        $args{loginid} = $client_vr->loginid;

        lives_ok { $rule_engine_vr->apply_rules($rule_name, %args, $field => 'xyz') } "Virtual is ok.";

        $client->status->setnx('duplicate_account', 'test', 'Duplicate account - currency change');

        is_deeply exception { $rule_engine_vr->apply_rules($rule_name, %args, $field => 'xyz') },
            {
            error_code  => 'CannotChangeAccountDetails',
            details     => {changed => [$field]},
            rule        => $rule_name,
            description => "$field field(s) are modified"
            },
            "Rule fails when non-empty immutable field $field is different for a vr with duplicated sibling";

        $client->status->upsert('duplicate_account', 'test', 'any reason');

        is exception { $rule_engine_vr->apply_rules($rule_name, %args, $field => 'xyz') }, undef,
            "Rule does not fail when non-empty immutable field $field is different for a vr without duplicated sibling";
    }

    for my $field (BOM::User::Client::FA_FIELDS_IMMUTABLE_DUPLICATED->@*) {
        $args{loginid} = $client->loginid;
        $client_mf->status->clear_duplicate_account;
        $client_mf->status->_build_all;
        $client_mf->db->dbic->run(
            fixup => sub {
                $_->do('DELETE FROM betonmarkets.financial_assessment WHERE client_loginid = ?', undef, $client_mf->loginid);
            });
        $client_mf->save;

        lives_ok { $rule_engine->apply_rules($rule_name, %args, $field => 'xyz') }
        "Rule passes when account is not duplicated";

        my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
        $client_mf->financial_assessment({
            data => encode_json_utf8($data),
        });
        $client_mf->save;
        lives_ok { $rule_engine->apply_rules($rule_name, %args, $field => 'xyz') }
        "Rule passes when account is not dup even if there is a change in the $field";

        $args{loginid} = $client_vr->loginid;
        lives_ok { $rule_engine_vr->apply_rules($rule_name, %args, $field => 'xyz') } "Virtual is ok.";

        $client_mf->status->setnx('duplicate_account', 'test', 'Duplicate account - currency change');

        is_deeply exception { $rule_engine_vr->apply_rules($rule_name, %args, $field => 'xyz') },
            {
            error_code => 'CannotChangeAccountDetails',
            details    => {changed => [$field]},
            rule       => $rule_name
            },
            "Rule fails when non-empty immutable field $field is different for a vr with duplicated sibling";

        $args{loginid} = $client->loginid;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args, $field => 'xyz') },
            {
            error_code => 'CannotChangeAccountDetails',
            details    => {changed => [$field]},
            rule       => $rule_name
            },
            "Rule fails when non-empty immutable field $field is different for a real with duplicated sibling";

        $client_mf->status->upsert('duplicate_account', 'test', 'any reason');
        $args{loginid} = $client_vr->loginid;
        is exception { $rule_engine_vr->apply_rules($rule_name, %args, $field => 'xyz') }, undef,
            "Rule does not fail when non-empty immutable field $field is different for a vr without duplicated sibling";

        $args{loginid} = $client->loginid;
        is exception { $rule_engine->apply_rules($rule_name, %args, $field => 'xyz') }, undef,
            "Rule does not fail when non-empty immutable field $field is different for a real without duplicated sibling";
    }

    for my $field (BOM::User::Client::FA_FIELDS_IMMUTABLE_DUPLICATED->@*) {
        $args{loginid} = $client->loginid;
        $client_mf->status->clear_duplicate_account;
        $client_mf->status->_build_all;
        $client_mf->db->dbic->run(
            fixup => sub {
                $_->do('DELETE FROM betonmarkets.financial_assessment WHERE client_loginid = ?', undef, $client_mf->loginid);
            });
        $client_mf->save;

        lives_ok { $rule_engine->apply_rules($rule_name, %args, $field => 'xyz') }
        "Rule passes when account is not duplicated";

        my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
        $client_mf->financial_assessment({
            data => encode_json_utf8($data),
        });
        $client_mf->save;
        lives_ok { $rule_engine->apply_rules($rule_name, %args, $field => 'xyz') }
        "Rule passes when account is not dup even if there is a change in the $field";

        $args{loginid} = $client_vr->loginid;

        lives_ok { $rule_engine_vr->apply_rules($rule_name, %args, $field => 'xyz') } "Virtual is ok.";

        $client_mf->status->setnx('duplicate_account', 'test', 'Duplicate account - currency change');

        is_deeply exception { $rule_engine_vr->apply_rules($rule_name, %args, $field => 'xyz') },
            {
            error_code => 'CannotChangeAccountDetails',
            details    => {changed => [$field]},
            rule       => $rule_name
            },
            "Rule fails when non-empty immutable field $field is different for a vr with duplicated sibling";

        $client_mf->status->upsert('duplicate_account', 'test', 'any reason');

        is exception { $rule_engine_vr->apply_rules($rule_name, %args, $field => 'xyz') }, undef,
            "Rule does not fail when non-empty immutable field $field is different for a vr without duplicated sibling";
    }
};

subtest 'rule client.is_not_virtual' => sub {
    my $rule_name   = 'client.is_not_virtual';
    my $rule_engine = BOM::Rules::Engine->new(client => [$client, $client_vr]);

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';
    my %args = (loginid => $client->loginid);

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes for real client';

    $args{loginid} = $client_vr->loginid;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'PermissionDenied',
        rule       => $rule_name
        },
        'Error with a virtual client';
};

subtest 'rule client.forbidden_postcodes' => sub {
    my $rule_name   = 'client.forbidden_postcodes';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';
    my %args = (loginid => $client->loginid);

    $client->residence('gb');
    $client->address_postcode('JE3');
    $client->save;

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'ForbiddenPostcode',
        rule       => $rule_name
        },
        'correct error when postcode is forbidden';

    $client->address_postcode('je3');
    $client->save;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'ForbiddenPostcode',
        rule       => $rule_name
        },
        'correct error when postcode is forbidden';

    $client->address_postcode('Je3');
    $client->save;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'ForbiddenPostcode',
        rule       => $rule_name
        },
        'correct error when postcode is forbidden';

    ok $rule_engine->apply_rules($rule_name, %args, address_postcode => 'EA1C'), 'Test passes with a valid postcode in args';

    $client->address_postcode('E1AC');
    $client->save;
    ok $rule_engine->apply_rules($rule_name, %args), 'Test passes with valid postcode';
};

my $rule_name = 'client.not_disabled';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    $client->status->set('disabled', 'test', 'test');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'DisabledAccount',
        rule       => $rule_name,
        params     => [$client->loginid]
        },
        'Error for disabled client';

    $client->status->clear_disabled;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if client is not disabled';
};

$rule_name = 'client.documents_not_expired';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    my $mock_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    $mock_documents->redefine(expired => 1);
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'DocumentsExpired',
        rule       => $rule_name
        },
        'Error for expired docs';

    $mock_documents->redefine(expired => 0);
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if docs are not expired';

    $mock_documents->unmock_all;
};

$rule_name = 'client.age_verified';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    $client->status->set('age_verification', 'x', 'x');

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if client has age_verification status';

    $client->status->clear_age_verification;

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'NotAgeVerified',
        rule       => $rule_name
        },
        'Error if client does not have age_verification status';

};

$rule_name = 'client.fully_authenticated';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(fully_authenticated => 0);
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'NotAuthenticated',
        rule       => $rule_name
        },
        'Error for unauthenticated client';

    $mock_client->redefine(fully_authenticated => 1);
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if client is authenticated';

    $mock_client->unmock_all;
};

$rule_name = 'client.financial_risk_approval_status';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    $client->status->clear_financial_risk_approval;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'FinancialRiskNotApproved',
        rule       => $rule_name
        },
        'Error if client has not approved risks';

    $client->status->set('financial_risk_approval', 'test', 'test');
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes with risk approval';
};

$rule_name = 'client.crs_tax_information_status';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    $client->status->clear_crs_tin_information;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'NoTaxInformation',
        rule       => $rule_name
        },
        'Error if client has not approved risks';

    $client->status->set('crs_tin_information', 'test', 'test');
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes with risk approval';
};

$rule_name = 'client.check_max_turnover_limit';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    my $lc_check_max_turnover;
    my $mock_landing_company = Test::MockModule->new('LandingCompany');
    $mock_landing_company->redefine(check_max_turnover_limit_is_set => sub { $lc_check_max_turnover });

    my $country_config = {};
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(countries_list => sub { return +{$client->residence => $country_config}; });

    my @test_cases = ({
            name                          => 'None requires - none set',
            lc_check_max_turnover         => 0,
            country_config                => {},
            ukgc_funds_protection_status  => 0,
            max_turnover_limit_set_status => 0,
            error                         => undef,
        },
        {
            name                          => 'Company requires max turnover - none set',
            lc_check_max_turnover         => 1,
            country_config                => {},
            ukgc_funds_protection_status  => 0,
            max_turnover_limit_set_status => 0,
            error                         => 'NoMaxTuroverLimit',
        },
        {
            name                          => 'Company requires max turnover - max turnver is set',
            lc_check_max_turnover         => 1,
            country_config                => {},
            ukgc_funds_protection_status  => 0,
            max_turnover_limit_set_status => 1,
            error                         => undef,
        },
        {
            name                          => 'Residence requires max turnover - none set',
            lc_check_max_turnover         => 0,
            country_config                => {need_set_max_turnover_limit => 1},
            ukgc_funds_protection_status  => 0,
            max_turnover_limit_set_status => 0,
            error                         => 'NoMaxTuroverLimit',
        },
        {
            name                          => 'Residence requires max turnover - max turnover is set',
            lc_check_max_turnover         => 0,
            country_config                => {need_set_max_turnover_limit => 1},
            ukgc_funds_protection_status  => 0,
            max_turnover_limit_set_status => 1,
            error                         => undef,
        },
        {
            name                  => 'Residence requires max turnover and ukgc - only max turnover is set',
            lc_check_max_turnover => 0,
            country_config        => {
                need_set_max_turnover_limit => 1,
                ukgc_funds_protection       => 1,
            },
            ukgc_funds_protection_status  => 0,
            max_turnover_limit_set_status => 1,
            error                         => 'NoUkgcFundsProtection',
        },
        {
            name                  => 'Residence requires max turnover and ukgc - max turnover and ukgc are set',
            lc_check_max_turnover => 0,
            country_config        => {
                need_set_max_turnover_limit => 1,
                ukgc_funds_protection       => 1,
            },
            ukgc_funds_protection_status  => 1,
            max_turnover_limit_set_status => 1,
            error                         => undef,
        },
    );

    for my $test_case (@test_cases) {
        $lc_check_max_turnover = $test_case->{lc_check_max_turnover};
        $country_config        = $test_case->{country_config};
        $client->status->set('ukgc_funds_protection',      'test', 'test') if $test_case->{ukgc_funds_protection_status};
        $client->status->set('max_turnover_limit_not_set', 'test', 'test') unless $test_case->{max_turnover_limit_set_status};

        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            $test_case->{error}
            ? {
            error_code => $test_case->{error},
            rule       => $rule_name
            }
            : undef,
            "testing: $test_case->{name}";

        $client->status->clear_ukgc_funds_protection;
        $client->status->clear_max_turnover_limit_not_set;
    }

    $mock_landing_company->unmock_all;
    $mock_countries->unmock_all;
};

$rule_name = 'client.no_unwelcome_status';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    $client->status->set('unwelcome', 'test', 'test');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'UnwelcomeStatus',
        rule       => $rule_name,
        params     => [$client->loginid],
        },
        'Error for unwelcome client';

    $client->status->clear_unwelcome;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if client is not unwecome';
};

$rule_name = 'client.no_withdrawal_or_trading_lock_status';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    $client->status->set('no_withdrawal_or_trading', 'test', 'test');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'NoWithdrawalOrTradingStatus',
        rule       => $rule_name
        },
        'Error for locked client';

    $client->status->clear_no_withdrawal_or_trading;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if client is not locked';
};

$rule_name = 'client.no_withdrawal_locked_status';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    $client->status->set('withdrawal_locked', 'test', 'test');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'WithdrawalLockedStatus',
        rule       => $rule_name
        },
        'Error for locked client';

    $client->status->clear_withdrawal_locked;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if client is not locked';
};

$rule_name = 'client.high_risk_authenticated';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    my $risk_level_aml = 'low';
    my $risk_level_sr  = 'low';
    my $authenticated  = 0;
    my $mock_client    = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(
        risk_level_aml      => sub { $risk_level_aml },
        risk_level_sr       => sub { $risk_level_sr },
        fully_authenticated => sub { $authenticated });

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if risk level is low and unauthenticated';
    $risk_level_aml = 'high';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'HighRiskNotAuthenticated',
        rule       => $rule_name
        },
        'Error for high aml risk client';

    $risk_level_aml = 'low';
    $risk_level_sr  = 'high';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'HighRiskNotAuthenticated',
        rule       => $rule_name
        },
        'Error for high SR risk client';

    $authenticated = 1;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if high risk client is authenticated';
};

$rule_name = 'client.potential_fraud_age_verified';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if potential fraud  and not age verified';

    $client->status->setnx('potential_fraud', 'system', 'Test');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'PotentialFraud',
        rule       => $rule_name
        },
        'Error for potential fraud client';

    $client->status->setnx('age_verification', 'system', 'Test');
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if potential fraud and age verifed';

    $client->status->clear_potential_fraud;
    $client->status->clear_age_verification;
};

$rule_name = 'client.account_is_not_empty';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'NoBalance',
        rule       => $rule_name,
        params     => [$client->loginid],
        },
        'correct error when currency is missing';

    BOM::Test::Helper::Client::top_up($client, $client->currency, 10);

    ok $rule_engine->apply_rules($rule_name, %args), 'Test passes when currency is set';
};

$rule_name = 'client.is_not_internal_client';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    $client->status->setnx('internal_client', 'system', 'test');

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'correct error when loginid is missing';

    my %args = (loginid => $client->loginid);
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'InternalClient',
        rule       => $rule_name,
        params     => [$client->loginid],
        },
        'correct error when client is an internal agent';

    $client->status->clear_internal_client;
    ok $rule_engine->apply_rules($rule_name, %args), 'Rule is applied when client is not an internal agent';
};

done_testing();
