use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr->set_default_account('USD');

my $user = BOM::User->create(
    email    => 'rules_wallet@test.deriv',
    password => 'qwe1231Q@!',
);
$user->add_client($client_cr);

my $rule_name = 'wallet.client_type_is_not_binary';
subtest $rule_name => sub {
    my %args        = (loginid => $client_cr->loginid);
    my $rule_engine = BOM::Rules::Engine->new(
        client => $client_cr,
        user   => $client_cr->user
    );

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'ClientAccountTypeIsBinary',
        rule       => $rule_name
        },
        'Client account type is binary';

    my $wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW'});
    $wallet->account_type('doughflow');
    $wallet->set_default_account('USD');
    $wallet->save;
    $user->add_client($wallet);
    %args        = (loginid => $wallet->loginid);
    $rule_engine = BOM::Rules::Engine->new(
        client => $wallet,
        user   => $wallet->user
    );
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Client account type is not binary';
};

done_testing();
