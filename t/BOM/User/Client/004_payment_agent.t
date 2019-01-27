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
});
$pa_client->save;

my $payment_agent_1 = BOM::User::Client::PaymentAgent->get_payment_agents('id', 'CR', 'USD');
ok($payment_agent_1->{'CR10001'});
ok($payment_agent_1->{'CR10001'}->{'currency_code'} eq 'USD');

my $payment_agent_2 = BOM::User::Client::PaymentAgent->get_payment_agents('id', 'CR');
ok($payment_agent_2->{'CR10001'});
ok($payment_agent_2->{'CR10001'}->{'currency_code'} eq 'USD');

dies_ok { BOM::User::Client::PaymentAgent->get_payment_agents() };

done_testing();
