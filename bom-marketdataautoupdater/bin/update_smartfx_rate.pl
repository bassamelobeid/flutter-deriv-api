#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::MarketDataAutoUpdater::Script::UpdateSmartFxRates;
exit BOM::MarketDataAutoUpdater::Script::UpdateSmartFxRates->new->run;
1;
