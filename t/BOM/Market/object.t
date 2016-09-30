use strict;
use warnings;

use Test::Most tests => 1;
use Test::Exception;
use Test::FailWarnings;

use BOM::Market;
use BOM::Market::Registry;

throws_ok { BOM::Market->new() } qr/Attribute \(name\) is required/, 'Name is Required';
