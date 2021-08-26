use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});

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
        error_code => 'DuplicateAccount',
        rule       => $rule_name
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
        rule       => $rule_name
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
        error_code => 'NoResidence',
        rule       => $rule_name
        },
        'Rule fails when residence is empty';

    $mock_client->unmock_all;
};

subtest 'rule client.signup_immitable_fields_not_changed' => sub {
    my $rule_name   = 'client.signup_immitable_fields_not_changed';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Client loginid is missing/, 'Client is required for this rule';
    my %args = (loginid => $client->loginid);

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies with no fields.';

    for my $field (qw/citizen place_of_birth residence/) {
        $client->$field('');
        $client->save;
        lives_ok { $rule_engine->apply_rules($rule_name, %args, $field => 'xyz') } "Rule applies if client's $field is empty.";

        $client->$field('af');
        $client->save;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args, $field => 'xyz') },
            {
            error_code => 'CannotChangeAccountDetails',
            details    => {changed => [$field]},
            rule       => $rule_name
            },
            "Rule fails when non-empty immutalbe fiel $field is different";
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

done_testing();
