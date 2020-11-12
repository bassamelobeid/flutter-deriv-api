use strict;
use warnings;

use Test::Most;
use Test::MockModule;

use Data::Dumper;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::RPC::v3::Utility;

use utf8;

my $server_name = 'qa20';
is BOM::RPC::v3::Utility::website_name($server_name), 'Binaryqa20.com';

$server_name = 'anynotexistqaserver';
is BOM::RPC::v3::Utility::website_name($server_name), 'Deriv.com';

done_testing();
