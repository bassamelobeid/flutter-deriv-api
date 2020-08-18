use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use BOM::User::Client::PaymentAgent;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( top_up );
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use BOM::Config::Runtime;

my $email       = 'JoeSmith@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

my $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client->set_default_account('USD');

# make him a payment agent
my $object_pa = $pa_client->payment_agent({
    payment_agent_name    => 'Joe',
    url                   => 'http://www.example.com/',
    email                 => 'joe@example.com',
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'USD',
    is_listed             => 't'
});
$pa_client->save;
$pa_client->get_payment_agent->set_countries(['id', 'pk']);
my $target_countries  = $pa_client->get_payment_agent->get_countries;
my $expected_result_1 = ['id', 'pk'];
is_deeply($target_countries, $expected_result_1, "returned correct countries");
$pa_client->payment_agent->information("The payment agent information is updated");
$pa_client->save;
is($pa_client->payment_agent->information, 'The payment agent information is updated', 'PA information is correct');
$target_countries = $pa_client->get_payment_agent->get_countries;
is_deeply($target_countries, $expected_result_1, "returned correct countries after update payment agent table");
#Added to check backward compatibility.
#TO-DO : must be removed when in future trigger on target_country column in payment_Agent is removed
$pa_client->payment_agent->target_country("vn");
$pa_client->save;
$target_countries = $pa_client->get_payment_agent->get_countries;
is_deeply($target_countries, ['vn'], "when target_country is updated now only one country i. e vn should be available.");
# set the countries again for normal flow
$pa_client->get_payment_agent->set_countries(['id', 'pk']);
my $payment_agent_1 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
    is_listed    => 't',
);
ok($payment_agent_1->{'CR10001'});
ok($payment_agent_1->{'CR10001'}->{'currency_code'} eq 'USD');
ok($payment_agent_1->{'CR10001'}->{'is_listed'} == 1);

my $payment_agent_2 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
    is_listed    => 'f',
);
is($payment_agent_2->{'CR10001'}, undef, 'agent not returned when is_listed is false');

my $payment_agent_3 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'pk',
    broker_code  => 'CR',
    currency     => 'USD',
);

is($payment_agent_3->{'CR10001'}->{'client_loginid'}, 'CR10001', 'agent is allowed two coutries so getting result even for country pk');
ok($payment_agent_3->{'CR10001'}->{'currency_code'} eq 'USD');
ok($payment_agent_3->{'CR10001'}->{'is_listed'} == 1);

my $payment_agent_4 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
);
ok($payment_agent_4->{'CR10001'});
ok($payment_agent_4->{'CR10001'}->{'currency_code'} eq 'USD');
ok($payment_agent_4->{'CR10001'}->{'is_listed'} == 1);

# Add new payment agent with is_listed = false
my $pa_client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client_2->set_default_account('USD');

# make him a payment agent
my $object_pa2 = $pa_client_2->payment_agent({
    payment_agent_name    => 'Joe',
    url                   => 'http://www.example.com/',
    email                 => 'joe@example.com',
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'USD',
    is_listed             => 'f'
});
$pa_client_2->save;
$pa_client_2->get_payment_agent->set_countries(['id', 'pk']);
my $payment_agent_5 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
    is_listed    => 't',
);
is($payment_agent_5->{'CR10002'}, undef);

my $payment_agent_6 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
    is_listed    => 'f',
);
ok($payment_agent_6->{'CR10002'});
ok($payment_agent_6->{'CR10002'}->{'currency_code'} eq 'USD');
ok($payment_agent_6->{'CR10002'}->{'is_listed'} == 0);

my $payment_agent_7 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
);
ok($payment_agent_7->{'CR10002'}, 'Agent returned because is_listed is not supplied');
ok($payment_agent_7->{'CR10002'}->{'currency_code'} eq 'USD');
ok($payment_agent_7->{'CR10002'}->{'is_listed'} == 0);

my $payment_agent_8 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
);
ok($payment_agent_8->{'CR10002'}, 'Agent returned because is_listed is not supplied');
ok($payment_agent_8->{'CR10002'}->{'currency_code'} eq 'USD');
ok($payment_agent_8->{'CR10002'}->{'is_listed'} == 0);

dies_ok { BOM::User::Client::PaymentAgent->get_payment_agents() };

# Add new payment agent to check validation for adding multiple target_countries
my $pa_client_3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client_3->set_default_account('USD');
# make him a payment agent
$pa_client_3->payment_agent({
    payment_agent_name    => 'Joe',
    url                   => 'http://www.example.com/',
    email                 => 'joe@example.com',
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'USD',
    is_listed             => 'f'
});
$pa_client_3->save;
BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries(['us']);
is($pa_client_3->get_payment_agent->set_countries(['id', 'us']), undef, 'Suspended country could not be added');
BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);
is($pa_client_3->get_payment_agent->set_countries(['id', 'any_country']), undef, 'Invalid country could not be added');
is($pa_client_3->get_payment_agent->set_countries(['id', 'at']),          undef, 'Countries from same landing company as payment agent is allowed');

done_testing();
