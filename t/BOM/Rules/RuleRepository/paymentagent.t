use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

subtest 'rule paymentagent.pa_allowed_in_landing_company' => sub {
    my $rule_name = 'paymentagent.pa_allowed_in_landing_company';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    BOM::User->create(
        email    => 'rules_pa@test.deriv',
        password => 'TEST PASS',
    )->add_client($client);

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    lives_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'This landing company is allowed';

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });
    dies_ok { $rule_engine->apply_rules($rule_name, loginid => $client->loginid) } 'This landing company is NOT allowed';
};

subtest 'rule paymentagent.paymentagent_shouldnt_already_exist' => sub {
    my $rule_name = 'paymentagent.paymentagent_shouldnt_already_exist';

    my $pa = BOM::User::Client::PaymentAgent->new({
        loginid     => 'CR0020',
        broker_code => 'CR'
    });
    my $pa_client = $pa->client;
    BOM::User->create(
        email    => 'rules_pa3@test.deriv',
        password => 'TEST PASS',
    )->add_client($pa_client);

    my $rule_engine = BOM::Rules::Engine->new(client => $pa_client);
    dies_ok { $rule_engine->apply_rules($rule_name, loginid => $pa_client->loginid) } 'paymentagent already exists';
};

done_testing();
