use strict;
use warnings;

use Test::Most;
use BOM::Test::CheckUserClientsUsage;

# Note, this test is to discourage further user of the $user->clients() pattern
# as doing so can instantiate a number of client instances every time it is called
# and a failure or issue with of one of the clients (VR) would cause a stall
# or a timeout. Do you really need to use $user->clients()??

# Note, if this test fails because you removed a call to $user->clients()
# just set the count to the new value.

my $repo = 'bom-rpc';
is(BOM::Test::CheckUserClientsUsage::check_count($repo), 9, "Usage of user->clients pattern in '$repo' matches expectations");

done_testing();
