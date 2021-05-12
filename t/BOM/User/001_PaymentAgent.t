use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::Client;

my $loginid1 = 'CR0020';
my $payment_agent;

#################################
# testing: new

Test::Exception::lives_ok { $payment_agent = BOM::User::Client::PaymentAgent->new({'loginid' => $loginid1}) } "Can get PaymentAgent client object";

my $class = ref $payment_agent;
is($class, 'BOM::User::Client::PaymentAgent', 'Class is BOM::User::Client::PaymentAgent');

#################################
# testing: intrinsic attributes

ok($payment_agent->is_authenticated, "payment agent is authenticated");

Test::Exception::lives_ok {
    $payment_agent->is_authenticated('');
    $payment_agent->save();
    $payment_agent->set_countries(['id', 'in']);
}
"set PaymentAgent authenticated to 'undef'";

ok(!$payment_agent->is_authenticated, "payment agent is not authenticated");

#################################
# testing: save

Test::Exception::lives_ok {
    $payment_agent->is_authenticated(1);
    $payment_agent->payment_agent_name('new name');
    $payment_agent->summary('new summary');
    $payment_agent->code_of_conduct_approval(1);
    $payment_agent->code_of_conduct_approval_time('1997-01-02 23:45');
    $payment_agent->save();
    $payment_agent->set_countries(['id', 'in']);
}
"save payment agent";

my $pa2 = BOM::User::Client::PaymentAgent->new({loginid => $payment_agent->client_loginid});
ok($pa2->summary, "new summary");
is $payment_agent->code_of_conduct_approval, 1, 'coc approval is correct';
my $expected_result_1 = ['id', 'in'];
my $target_countries  = $pa2->get_countries;
is_deeply($target_countries, $expected_result_1, "returned correct countries");

#################################
# testing: client

my $client2 = $pa2->client;
ok($client2, "mandatory Client object exists for $loginid1");
is(ref($client2), 'BOM::User::Client', 'related client is the (smarter) BP::Client not the base Rose object');
$pa2 = $client2->get_payment_agent;
is $pa2->code_of_conduct_approval_date, '1997-01-02', 'coc approval time is correctly converted to date';

