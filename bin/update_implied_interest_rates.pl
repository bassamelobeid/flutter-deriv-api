#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use BOM::MarketDataAutoUpdater::Script::UpdateImpliedInterestRates;
exit BOM::MarketDataAutoUpdater::Script::UpdateImpliedInterestRates->new()->run();
