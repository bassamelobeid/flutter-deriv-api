#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::MarketDataAutoUpdater::Script::UpdateOhlc;
exit BOM::MarketDataAutoUpdater::Script::UpdateOhlc->new->run;
