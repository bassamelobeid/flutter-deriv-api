use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Client;

my $login_id = 'CR0011';
my $client;

is(scalar(keys BOM::Platform::Client::client_status_types), 12, "correct number of client status");

Test::Exception::lives_ok { $client = BOM::Platform::Client::get_instance({loginid => $login_id}) } "Can create client $login_id";

my $broker = $client->broker;

my $undef;
my $reason = "test to set unwelcome login";
my $clerk  = 'shuwnyuan';

# first time, client cashier is not lock
is($client->get_status('unwelcome'), $undef, "client is not in unwelcome login");

# lock client cashier
Test::Exception::lives_ok { $client->set_status('unwelcome', $clerk, $reason) } "set client unwelcome login";

# save changes to CR.lockcashierlogins
Test::Exception::lives_ok { $client->save() } "can save to unwelcome login file";

# recreate client
Test::Exception::lives_ok { $client = BOM::Platform::Client::get_instance({loginid => $login_id}) } "Can create client $login_id";

# re-read from CR.lockcashierlogins, whether client is disabled cashier
my $unwelcome = $client->get_status('unwelcome');
is($unwelcome->reason,     $reason, "client is in unwelcome login, reason OK");
is($unwelcome->staff_name, $clerk,  "client is in unwelcome login, clerk OK");

# enable client cashier back
Test::Exception::lives_ok { $client->clr_status('unwelcome') } "delete client from unwelcome login";

# save changes to CR.lockcashierlogins
Test::Exception::lives_ok { $client->save } "can save to unwelcome login file";
