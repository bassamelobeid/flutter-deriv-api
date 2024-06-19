#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::MarketDataAutoUpdater::Script::UpdateVol;
exit BOM::MarketDataAutoUpdater::Script::UpdateVol->new->run;

