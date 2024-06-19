#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::MarketDataAutoUpdater::Script::UpdateInterestRates;
exit BOM::MarketDataAutoUpdater::Script::UpdateInterestRates->new->run;
