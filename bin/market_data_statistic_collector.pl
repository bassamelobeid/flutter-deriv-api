#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Market::Script::MarketDataStatisticCollector;

exit BOM::Market::Script::MarketDataStatisticCollector->new->run;
