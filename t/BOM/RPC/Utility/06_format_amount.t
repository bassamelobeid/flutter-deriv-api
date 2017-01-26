use strict;
use warnings;

use Test::Most;
use BOM::RPC::v3::Utility;

is BOM::RPC::v3::Utility::format_amount('USD', 10), '10.00', 'USD 10 -> 10.00';
is BOM::RPC::v3::Utility::format_amount('USD', 10.000001), '10.00', 'USD 10.000001 -> 10.00';
is BOM::RPC::v3::Utility::format_amount('XBT', 10), '10.00000000', 'XBT 10 -> 10.00000000';
is BOM::RPC::v3::Utility::format_amount('XBT', 10.000001), '10.00000100', 'XBT 10.000001 -> 10.00000100';
is BOM::RPC::v3::Utility::format_amount('XBT', 10.0000000000001), '10.00000000', 'XBT 10.0000000000001 -> 10.00000000';

throws_ok {
    BOM::RPC::v3::Utility::format_amount('FOO', 1);
}
qr/wrong currency for rounding/, 'No format for unknow currency';

done_testing();
