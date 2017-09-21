#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::MarketData::FeedJump;
exit BOM::MarketData::FeedJump->new->run();
