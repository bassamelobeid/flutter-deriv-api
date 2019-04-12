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
$pa_client->payment_agent({
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
    target_country        => 'id',
    is_listed             => 't'
});
$pa_client->save;

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
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
);
ok($payment_agent_3->{'CR10001'});
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
$pa_client_2->payment_agent({
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
    target_country        => 'id',
    is_listed             => 'f'
});
$pa_client_2->save;

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

done_testing();
