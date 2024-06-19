#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::MarketDataAutoUpdater::Script::CryptoMonitor;
exit BOM::MarketDataAutoUpdater::Script::CryptoMonitor->new->run;
