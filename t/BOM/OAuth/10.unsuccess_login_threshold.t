use strict;
use warnings;
use Test::More;
use BOM::OAuth::Common;

is(BOM::OAuth::Common->BLOCK_TRIGGER_COUNT,  "10",    "Threshold for unsuccessful login ip");
is(BOM::OAuth::Common->BLOCK_MIN_DURATION,   "300",   "Threshold for minimum duration in seconds");
is(BOM::OAuth::Common->BLOCK_MAX_DURATION,   "86400", "Threshold for maximum duration in seconds");
is(BOM::OAuth::Common->BLOCK_TRIGGER_WINDOW, "300",   "Threshold trigger window in seconds");

done_testing();

