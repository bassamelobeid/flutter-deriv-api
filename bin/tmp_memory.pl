use strict;
use warnings;
use BOM::Test::LoadTest::Pricer qw(dd_memory);

dd_memory(1,'forex');
sleep 10;
dd_memory(0, 'forex');
