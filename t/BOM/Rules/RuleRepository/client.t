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

my $rule_engine = BOM::Rules::Engine->new(client => $client);

subtest 'rule profile.address_postcode_mandatory' => sub {
    my $rule_name = 'profile.address_postcode_mandatory';
    $client->address_postcode('');

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {error_code => 'PostcodeRequired'}, 'correct error when postcode is missing';

    ok $rule_engine->apply_rules($rule_name, {address_postcode => '123'}), 'Test passes with a postcode in args';

    $client->address_postcode('345');
    ok $rule_engine->apply_rules($rule_name), 'Test passes with non-empty postcode';
};

subtest 'rule profile.no_pobox_in_address' => sub {
    my $rule_name = 'profile.no_pobox_in_address';

    for my $arg (qw/address_line_1 address_line_2/) {
        for my $value ('p.o. box', 'p o. box', 'p o box', 'P.O Box', 'Po. BOX') {
            is_deeply exception { $rule_engine->apply_rules($rule_name, {$arg => $value}) }, {error_code => 'PoBoxInAddress'}, "$value is rejected";
        }
    }

    ok $rule_engine->apply_rules($rule_name, {address_line_1 => 'There is no pobox here'}), 'It passes with a slight change in spelling';
    ok $rule_engine->apply_rules($rule_name), 'Missing address in args is accepted';
};

subtest 'rule client.check_duplicate_account' => sub {
    my $rule_name   = 'client.check_duplicate_account';
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(check_duplicate_account => sub { return 1 });

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {error_code => 'DuplicateAccount'}, "Duplicate accounnt is rejected";
    $mock_client->redefine(check_duplicate_account => sub { return 0 });
    ok $rule_engine->apply_rules($rule_name), 'Non-duplicate account is accepted';

    $mock_client->unmock_all;
};

subtest 'rule client.has_currency_set' => sub {
    my $rule_name = 'client.has_currency_set';

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {error_code => 'SetExistingAccountCurrency'},
        'correct error when currency is missing';

    $client->set_default_account('USD');

    ok $rule_engine->apply_rules($rule_name), 'Test passes when currency is set';
};

subtest 'rule client.residence_is_not_empty' => sub {
    my $rule_name = 'client.residence_is_not_empty';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    my $residence   = 'id';
    $mock_client->redefine(residence => sub { return $residence });

    lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule applies when residence is set.';

    $residence = undef;
    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {error_code => 'NoResidence'}, 'Rule fails when residence is empty';

    $mock_client->unmock_all;
};

subtest 'rule client.signup_immitable_fields_not_changed' => sub {
    my $rule_name = 'client.signup_immitable_fields_not_changed';

    lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule applies with empty args.';

    for my $field (qw/citizen place_of_birth residence/) {
        $client->$field('');
        $client->save;
        lives_ok { $rule_engine->apply_rules($rule_name, {$field => 'xyz'}) } "Rule applies if client's $field is empty.";

        $client->$field('af');
        $client->save;
        is_deeply exception { $rule_engine->apply_rules($rule_name, {$field => 'xyz'}) },
            {
            error_code => 'CannotChangeAccountDetails',
            details    => {changed => [$field]}
            },
            "Rule fails when non-empty immutalbe fiel $field is different";
    }

};

subtest 'rule client.is_not_virtual' => sub {
    my $rule_name = 'client.is_not_virtual';

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    lives_ok { $rule_engine->apply_rules($rule_name) } 'Test passes for real client';

    $rule_engine = BOM::Rules::Engine->new(client => $client_vr);
    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {error_code => 'PermissionDenied'}, 'Error with a virtual client';
};

done_testing();
