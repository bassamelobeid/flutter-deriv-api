use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Fatal qw(lives_ok);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::Client;

#my $password = 'jskjd8292922';
#my $hash_pwd = BOM::User::Password::hashpw($password);

#$email = 'exists_email' . rand(999) . '@binary.com';

my $user = BOM::User->create(
    email    => 'closed_accounts@test.com',
    password => 'pwd'
);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$user->add_client($client_vr);

ok !$user->is_closed, 'new user not closed';

$client_vr->status->set('disabled', 1, 'test disabled');
ok $user->is_closed, 'closed after disabled status set on only account';

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$user->add_client($client_cr);
ok !$user->is_closed, "not closed after adding sibling accont";

$client_cr->status->set('disabled', 1, 'test disabled');
ok $user->is_closed, 'closed after setting disabled status on sibling account';

done_testing();
