use strict;
use warnings;

use Test::More                                 qw(no_plan);
use Test::Fatal                                qw(lives_ok);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;

my $test_customer = BOM::Test::Customer->create(
    clients => [{
            name        => 'VRTC',
            broker_code => 'VRTC',
        }]);
my $client_vr = $test_customer->get_client_object('VRTC');
my $user      = $client_vr->user;

ok !$user->is_closed, 'new user not closed';

$client_vr->status->set('disabled', 1, 'test disabled');
ok $user->is_closed, 'closed after disabled status set on only account';

my $client_cr = $test_customer->create_client(
    name        => 'CR',
    broker_code => 'CR'
);
# Make a new user at the clients are cached and new one wont be visible in that user
$user = $client_vr->user;

ok !$user->is_closed, "not closed after adding sibling account";

$client_cr->status->set('disabled', 1, 'test disabled');
ok $user->is_closed, 'closed after setting disabled status on sibling account';

done_testing();
