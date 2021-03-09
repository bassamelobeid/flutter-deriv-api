use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::Client;

my $login_id = 'CR0011';
my $client;

Test::Exception::lives_ok { $client = BOM::User::Client::get_instance({'loginid' => $login_id}); }
"Can create client object 'BOM::User::Client::get_instance({'loginid' => $login_id})'";

my $broker = $client->broker;

my $undef;
my $reason = "test to disable cashier";
my $clerk  = 'shuwnyuan';

is($client->status->cashier_locked,    $undef, "client is not disable cashier");
is($client->status->withdrawal_locked, $undef, 'client is not withdrawal_locked');

# lock client cashier
Test::Exception::lives_ok { $client->status->set('cashier_locked',    $clerk, $reason) } "set client disable cashier";
Test::Exception::lives_ok { $client->status->set('withdrawal_locked', $clerk, $reason) } "set client withdrawal_locked";

# recreate client
Test::Exception::lives_ok { $client = BOM::User::Client::get_instance({loginid => $login_id}) } "Can create client $login_id";

# re-read from CR.lockcashierlogins, whether client is disabled cashier
my $lock_ref = $client->status->cashier_locked;
is($lock_ref->{reason},     $reason, "client is disable cashier, reason OK");
is($lock_ref->{staff_name}, $clerk,  "client is disable cashier, clerk OK");

$lock_ref = $client->status->withdrawal_locked;
is($lock_ref->{reason},     $reason, "client is withdrawal_locked, reason OK");
is($lock_ref->{staff_name}, $clerk,  "client is withdrawal_locked, clerk OK");

Test::Exception::lives_ok { $client->status->clear_cashier_locked } "set client enable cashier";
Test::Exception::lives_ok { $client->status->clear_withdrawal_locked } "set client enable withdrawal";
