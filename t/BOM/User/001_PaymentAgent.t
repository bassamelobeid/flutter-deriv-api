use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use User::Client;

my $loginid1 = 'CR0020';
my $payment_agent;

#################################
# testing: new

Test::Exception::lives_ok { $payment_agent = User::Client::PaymentAgent->new({'loginid' => $loginid1}) } "Can get PaymentAgent client object";

my $class = ref $payment_agent;
is($class, 'User::Client::PaymentAgent', 'Class is User::Client::PaymentAgent');

#################################
# testing: intrinsic attributes

ok($payment_agent->is_authenticated, "payment agent is authenticated");

Test::Exception::lives_ok {
    $payment_agent->is_authenticated('');
    $payment_agent->save();
}
"set PaymentAgent authenticated to 'undef'";

ok(!$payment_agent->is_authenticated, "payment agent is not authenticated");

#################################
# testing: save

Test::Exception::lives_ok {
    $payment_agent->is_authenticated(1);
    $payment_agent->payment_agent_name('new name');
    $payment_agent->summary('new summary');
    $payment_agent->save();
}
"save payment agent";

my $pa2 = User::Client::PaymentAgent->new({loginid => $payment_agent->client_loginid});
ok($pa2->summary, "new summary");

#################################
# testing: client

my $client2 = $pa2->client;
ok($client2, "mandatory Client object exists for $loginid1");
is(ref($client2), 'User::Client', 'related client is the (smarter) BP::Client not the base Rose object');

