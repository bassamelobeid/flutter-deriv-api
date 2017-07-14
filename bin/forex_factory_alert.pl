#!/usr/bin/perl

use strict;
use warnings;

use BOM::MarketDataAutoUpdater::Script::ForexFactoryAlert;

exit BOM::MarketDataAutoUpdater::Script::ForexFactoryAlert->new->run();
