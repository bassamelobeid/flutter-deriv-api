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
my $user = BOM::User->create(
    email    => 'rules_lc@test.deriv',
    password => 'TEST PASS',
);
$user->add_client($client);

subtest 'rule landing_company.accounts_limit_not_reached' => sub {
    my $rule_name = 'landing_company.accounts_limit_not_reached';

    my $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        landing_company => 'svg'
    );
    lives_ok { $rule_engine->apply_rules($rule_name) } 'There is no limit on svg';

    $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        landing_company => 'malta'
    );
    lives_ok { $rule_engine->apply_rules($rule_name) } 'There is no malta account so it is ok';

    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    $user->add_client($client_mlt);
    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {error_code => 'NewAccountLimitReached'}, 'Number of MLT accounts is limited';

    $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        landing_company => 'maltainvest'
    );
    lives_ok { $rule_engine->apply_rules($rule_name) } 'There is no maltainvest account so it is ok';

    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    $user->add_client($client_mf);
    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {error_code => 'FinancialAccountExists'}, 'Number of MF accounts is limited';

    lives_ok { $rule_engine->apply_rules($rule_name, {account_type => 'wallet'}) } 'Wallet accounts is not restricted by trading accounts';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(is_wallet => sub { 1 });
    lives_ok { $rule_engine->apply_rules($rule_name, {account_type => 'wallet'}) } 'Wallet accounts is not restricted';
    $mock_client->unmock_all;

    $client_mf->status->set('disabled', 'test', 'test');
    lives_ok { $rule_engine->apply_rules($rule_name) } 'Disabled accounts are excluded';
};

subtest 'rule landing_company.required_fields_are_non_empty' => sub {
    my $rule_name   = 'landing_company.required_fields_are_non_empty';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my $args = {
        first_name => '',
        last_name  => ''
    };

    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->redefine(requirements => sub { return +{signup => [qw(first_name last_name)]}; });

    is_deeply exception { $rule_engine->apply_rules($rule_name, $args) },
        {
        error_code => 'InsufficientAccountDetails',
        details    => {missing => [qw(first_name last_name)]}
        },
        'Error with missing client data';

    $args = {
        first_name => 'Master',
        last_name  => 'Mind'
    };
    lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Test passes when client has the data';

    $mock_lc->unmock_all;
};

subtest 'rule landing_company.currency_is_allowed' => sub {
    my $rule_name   = 'landing_company.currency_is_allowed';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->redefine(is_currency_legal => sub { return 0 });
    lives_ok { $rule_engine->apply_rules($rule_name) } 'Empty currency is accepted';
    is_deeply exception { $rule_engine->apply_rules($rule_name, {currency => 'USD'}) },
        {
        error_code => 'CurrencyNotAllowed',
        params     => 'USD'
        },
        'Error for illegal currency';

    $mock_lc->redefine(is_currency_legal => sub { return 1 });
    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'USD'}) } 'The currency is legal now';

    $mock_lc->unmock_all;
};

subtest 'rule landing_company.p2p_availability' => sub {
    my $rule_name   = 'landing_company.p2p_availability';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->redefine(p2p_available => sub { return 1 });

    lives_ok { $rule_engine->apply_rules($rule_name) } 'Empty args are accepted';
    lives_ok { $rule_engine->apply_rules($rule_name, {account_opening_reason => 'p2p'}) } 'It always passes if p2p is available';

    $mock_lc->redefine(p2p_available => sub { return 0 });
    lives_ok { $rule_engine->apply_rules($rule_name, {account_opening_reason => 'dummy'}) } 'any p2p unrelated reason is fine';

    is_deeply exception { $rule_engine->apply_rules($rule_name, {account_opening_reason => 'p2p'}) }, {error_code => 'P2PRestrictedCountry'},
        'It fails for a p2p related reason in args';

    $mock_lc->unmock_all;
};

done_testing();
