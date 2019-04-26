use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Fatal qw(lives_ok);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::Client;

my $login_id = 'CR0011';
my $client;

lives_ok { $client = BOM::User::Client::get_instance({loginid => $login_id}) } "Can create client $login_id";

my $broker = $client->broker;

my $reason = "test address verified status";
my $clerk  = 'shuwnyuan';

# address is yet to be verified
is($client->status->address_verified, undef, "Address is not yet verified");

# address_verified status can be set
lives_ok { $client->status->set('address_verified', $clerk, $reason) };

# client has address verified status
ok (defined $client->status->address_verified , "client is address_verified");

# re-read to check if details are the same
my $address_verified_status = $client->status->address_verified;
is($address_verified_status->{reason},     $reason, "client is in address_verified, reason OK");
is($address_verified_status->{staff_name}, $clerk,  "client is in address_verified, clerk OK");

# remove address_verified status
lives_ok { $client->status->clear_address_verified } "remove address_verified status";

# address_verified status should be cleared
is($client->status->address_verified, undef, "address_verified status is cleared");