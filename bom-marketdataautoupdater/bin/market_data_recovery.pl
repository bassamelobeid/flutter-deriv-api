#!/usr/bin/perl

use strict;
use warnings;

### This is the DR recovery script for quants market data ###
#
# This script will restore the following redis cache data from chronicle database:
# - economic_events
# - volatility_surfaces
# - interest_rates
# - dividends
# - holidays
# - correlation_matrices
# - predefined_parameters
# - app_settings
#
# This script will restore contract buy/sell operations given that chronicle
# database has the most recent market data.

use BOM::MarketDataAutoUpdater::DisasterRecovery;

BOM::MarketDataAutoUpdater::DisasterRecovery->new->run;
1;
