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

my $rule_engine = BOM::Rules::Engine->new(client => $client);

subtest 'rule client.address_postcode_mandatory' => sub {
    my $rule_name = 'client.address_postcode_mandatory';
    $client->address_postcode('');

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'PostcodeRequired'}, 'correct error when postcode is missing';

    ok $rule_engine->apply_rules($rule_name, {address_postcode => '123'}), 'Test passes with a postcode in args';

    $client->address_postcode('345');
    ok $rule_engine->apply_rules($rule_name), 'Test passes with non-empty postcode';
};

subtest 'rule client.no_pobox_in_address' => sub {
    my $rule_name = 'client.no_pobox_in_address';

    for my $arg (qw/address_line_1 address_line_2/) {
        for my $value ('p.o. box', 'p o. box', 'p o box', 'P.O Box', 'Po. BOX') {
            is_deeply exception { $rule_engine->apply_rules($rule_name, {$arg => $value}) }, {code => 'PoBoxInAddress'}, "$value is rejected";
        }
    }

    ok $rule_engine->apply_rules($rule_name, {address_line_1 => 'There is no pobox here'}), 'It passes with a slight change in spelling';
    ok $rule_engine->apply_rules($rule_name), 'Missing address in args is accepted';
};

subtest 'rule client.check_duplicate_account' => sub {
    my $rule_name   = 'client.check_duplicate_account';
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(check_duplicate_account => sub { return 1 });

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'DuplicateAccount'}, "Duplicate accounnt is rejected";
    $mock_client->redefine(check_duplicate_account => sub { return 0 });
    ok $rule_engine->apply_rules($rule_name), 'Non-duplicate account is accepted';

    $mock_client->unmock_all;
};

subtest 'rule client.has_currency_set' => sub {
    my $rule_name = 'client.has_currency_set';

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'SetExistingAccountCurrency'}, 'correct error when currency is missing';

    $client->set_default_account('USD');

    ok $rule_engine->apply_rules($rule_name), 'Test passes when currency is set';
};

subtest 'rule client.required_fields_are_non_empty' => sub {
    my $rule_name   = 'client.required_fields_are_non_empty';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    $client->first_name('');
    $client->last_name('');
    $client->save;

    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->redefine(requirements => sub { return +{signup => [qw(first_name last_name)]}; });

    is_deeply exception { $rule_engine->apply_rules($rule_name) },
        {
        code    => 'InsufficientAccountDetails',
        details => {missing => [qw(first_name last_name)]}
        },
        'Error with missing client data';

    $client->first_name('Mister');
    $client->last_name('family');
    $client->save;

    lives_ok { $rule_engine->apply_rules($rule_name) } 'Test passes when client has the data';

    $mock_lc->unmock_all;
};
done_testing();
