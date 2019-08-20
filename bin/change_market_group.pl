#!/usr/bin/perl

use strict;
use warnings;

### WHAT DOES THIS SCRIPT DO AND WHY?
#
# Limits are applied based on the market definition of a symbol in bet.limits_market_mapper table. These definition is mostly similar to the
# definitions found in underlyings.yml, but it could be changed from the backoffice. For example, the market group for
# frxUSDJPY, frxAUDJPY, frxGBPJPY is forex. In some events, quants might decide to set a tighter limit to JPY forex pairs.
#
# So, they first switch the market group to a new name (E.g. jpy_pairs) and then a new set of limits is applied to jpy_pairs market group.
# Note that setting individual limit for each JPY pair will have a different effect.
#
# Everything is well until someone decide to set a new market group for a list of underlying symbols and at the same time, set a limit on the new market group.
# This script does switching of market group at the specified time and at the same time remove expired quants related config.

use BOM::Database::QuantsConfig;
my $qc = BOM::Database::QuantsConfig->new;
# switches market group to new market or reverting it to previous market
$qc->switch_pending_market_group();
# clean up the old records in betonmarkets.quants_wishlist and the global limit tables.
$qc->cleanup_expired_quants_config();
1;
