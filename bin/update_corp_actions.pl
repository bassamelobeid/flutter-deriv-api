#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::MarketDataAutoUpdater::Script::UpdateCorpActions;
exit  BOM::MarketDataAutoUpdater::Script::UpdateCorpActions->new->run;
