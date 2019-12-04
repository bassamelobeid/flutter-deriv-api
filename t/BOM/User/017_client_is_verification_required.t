use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Fatal qw(lives_ok);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::Client;
use BOM::User;

my $email = 'abc@binary.com';

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    email       => $email,
    residence   => 'gb',
});

my $user = BOM::User->create(
    email    => $email,
    password => 'test',
);

$user->add_client($client_vr);
$user->add_client($client_mx);

is($client_vr->is_verification_required(), 0, "vr client needn't verification");
$client_mx->status->set('age_verification', 'system', 'testing');

is($client_mx->is_verification_required(check_authentication_status => 1),
    1, "check_authentication_status in gb and no id_online will require verification");
$client_mx->status->set('unwelcome', 'system', 'testing');
is($client_mx->is_verification_required(check_authentication_status => 1),
    1, "check_authentication_status in gb and no id_online and unwelcome still require verification");

done_testing();
