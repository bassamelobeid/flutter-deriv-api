use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Client;

my $login_id = 'CR0011';
my $client;

Test::Exception::lives_ok { $client = BOM::Platform::Client::get_instance({'loginid' => $login_id}); }
"Can create client object 'BOM::Platform::Client::get_instance({'loginid' => $login_id})'";

my $broker = $client->broker;

my $undef;
my $reason = "test to disable cashier";
my $clerk  = 'shuwnyuan';

is($client->get_status('cashier_locked'),    $undef, "client is not disable cashier");
is($client->get_status('withdrawal_locked'), $undef, 'client is not withdrawal_locked');

# lock client cashier
Test::Exception::lives_ok { $client->set_status('cashier_locked',    $clerk, $reason) } "set client disable cashier";
Test::Exception::lives_ok { $client->set_status('withdrawal_locked', $clerk, $reason) } "set client withdrawal_locked";

# save changes to CR
Test::Exception::lives_ok { $client->save } "can save client with new status";

# recreate client
Test::Exception::lives_ok { $client = BOM::Platform::Client::get_instance({loginid => $login_id}) } "Can create client $login_id";

# re-read from CR.lockcashierlogins, whether client is disabled cashier
my $lock_ref = $client->get_status('cashier_locked');
is($lock_ref->reason,     $reason, "client is disable cashier, reason OK");
is($lock_ref->staff_name, $clerk,  "client is disable cashier, clerk OK");

$lock_ref = $client->get_status('withdrawal_locked');
is($lock_ref->reason,     $reason, "client is withdrawal_locked, reason OK");
is($lock_ref->staff_name, $clerk,  "client is withdrawal_locked, clerk OK");

Test::Exception::lives_ok { $client->clr_status('cashier_locked') } "set client enable cashier";
Test::Exception::lives_ok { $client->clr_status('withdrawal_locked') } "set client enable withdrawal";
Test::Exception::lives_ok { $client->save } "can save client with unlocked status";
Test::Exception::lives_ok { $client->save } "can save client with authentication status removed";

