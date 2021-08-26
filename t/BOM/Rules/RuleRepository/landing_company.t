use strict;
use warnings;
no indirect;

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

my $rule_engine = BOM::Rules::Engine->new(client => $client);

subtest 'rule landing_company.accounts_limit_not_reached' => sub {
    my $rule_name = 'landing_company.accounts_limit_not_reached';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/landing_company is required/, 'Fails without landing company';
    my %args = (landing_company => 'malta');
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Client loginid is missing/, 'Fails without client loginid';
    $args{loginid} = $client->loginid;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'There is no malta account so it is ok';

    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    $user->add_client($client_mlt);
    my $engine = BOM::Rules::Engine->new(client => $client_mlt);

    $args{loginid} = $client_mlt->loginid;
    is_deeply exception { $engine->apply_rules($rule_name, %args) },
        {
        error_code => 'NewAccountLimitReached',
        rule       => $rule_name
        },
        'Number of MLT accounts is limited';

    $args{landing_company} = 'maltainvest';
    lives_ok { $engine->apply_rules($rule_name, %args) } 'There is no maltainvest account so it is ok';

    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    $user->add_client($client_mf);
    $engine = BOM::Rules::Engine->new(client => [$client_mlt, $client_mf]);
    is_deeply exception { $engine->apply_rules($rule_name, %args) },
        {
        error_code => 'FinancialAccountExists',
        rule       => $rule_name
        },
        'Number of MF accounts is limited';

    $args{account_type} = 'wallet';
    lives_ok { $engine->apply_rules($rule_name, %args) } 'Wallet accounts is not restricted by trading accounts';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(is_wallet => sub { 1 });
    lives_ok { $engine->apply_rules($rule_name, %args) } 'Wallet accounts is not restricted';
    $mock_client->unmock_all;

    $args{account_type} = 'trading';
    $client_mf->status->set('duplicate_account', 'test', 'test');
    lives_ok { $engine->apply_rules($rule_name, %args) } 'Duplicate accounts are ignored';
    $client_mf->status->clear_duplicate_account;

    $client_mf->status->set('disabled', 'test', 'test');
    is_deeply exception { $engine->apply_rules($rule_name, %args) },
        {
        error_code => 'NewAccountLimitReached',
        rule       => 'landing_company.accounts_limit_not_reached'
        },
        'Number of MF accounts is limited - disabled accounts included';
};

subtest 'rule landing_company.required_fields_are_non_empty' => sub {
    my $rule_name = 'landing_company.required_fields_are_non_empty';

    my %args = (
        loginid    => $client->loginid,
        first_name => '',
        last_name  => ''
    );

    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->redefine(requirements => sub { return +{signup => [qw(first_name last_name)]}; });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'InsufficientAccountDetails',
        details    => {missing => [qw(first_name last_name)]},
        rule       => $rule_name
        },
        'Error with missing client data';

    %args = (
        loginid    => $client->loginid,
        first_name => 'Master',
        last_name  => 'Mind'
    );
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes when client has the data';

    $mock_lc->unmock_all;
};

subtest 'rule landing_company.currency_is_allowed' => sub {
    my $rule_name = 'landing_company.currency_is_allowed';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either landing_company or loginid is required/, 'Landing company is required';
    my %args = (landing_company => 'svg');

    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Client loginid is missing/, 'Landing company is required';
    $args{loginid} = $client->loginid;

    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->redefine(is_currency_legal => sub { return 0 });
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Succeeds with no currency - even when all currencies are illegal';

    $args{currency} = 'USD';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CurrencyNotApplicable',
        params     => 'USD',
        rule       => $rule_name
        },
        'Error for illegal currency';

    $mock_lc->redefine(is_currency_legal => sub { return 1 });
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'The currency is legal now';

    $mock_lc->unmock_all;
};

subtest 'rule landing_company.p2p_availability' => sub {
    my $rule_name = 'landing_company.p2p_availability';

    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->redefine(p2p_available => sub { return 1 });

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either landing_company or loginid is required/, 'Landing company is required';
    my %args = (landing_company => 'svg');
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Empty args are accepted';
    $args{account_opening_reason} = 'p2p';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'It always passes if p2p is available';

    $mock_lc->redefine(p2p_available => sub { return 0 });
    $args{account_opening_reason} = 'dummy';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'any p2p unrelated reason is fine';

    $args{account_opening_reason} = 'p2p exchange';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'P2PRestrictedCountry',
        rule       => 'landing_company.p2p_availability'
        },
        'It fails for a p2p related reason in args';

    $args{account_opening_reason} = 'Peer-to-peer exchange';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'P2PRestrictedCountry',
        rule       => 'landing_company.p2p_availability'
        },
        "It fails when reason is 'Peer-to-peer exchange'";

    $mock_lc->unmock_all;
};

done_testing();
