use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::Client;

my $login_id = 'CR0011';
my $client;

Test::Exception::lives_ok { $client = BOM::User::Client::get_instance({loginid => $login_id}) } "Can create client $login_id";

my $broker = $client->broker;

my $reason = "test to set unwelcome login";
my $clerk  = 'shuwnyuan';

# first time, client cashier is not lock
is($client->status->unwelcome, undef, "client is not in unwelcome login");

# lock client cashier
Test::Exception::lives_ok { $client->status->set('unwelcome', $clerk, $reason) } "set client unwelcome login";

# recreate client
Test::Exception::lives_ok { $client = BOM::User::Client::get_instance({loginid => $login_id}) } "Can create client $login_id";

# re-read from CR.lockcashierlogins, whether client is disabled cashier
my $unwelcome = $client->status->unwelcome;
is($unwelcome->{reason},     $reason, "client is in unwelcome login, reason OK");
is($unwelcome->{staff_name}, $clerk,  "client is in unwelcome login, clerk OK");

# enable client cashier back
Test::Exception::lives_ok { $client->status->clear_unwelcome } "delete client from unwelcome login";
