use strict;
use warnings;
use BOM::Test::LoadTest::Pricer qw(dd_memory_and_time);

dd_memory('forex');
sleep 10;
dd_memory();
