#!/usr/bin/perl

#########################################################################
# update_mt5_trading_rights_and_status                                  #
# This script is used to gather the clients with poa_pending status     #
# If the poa_pending status is 5 days for vanuatu or 10 days for bvi    #
# we update the status to poa_failed and update their trading rights    #
# to red flag in mt5                                                    #
#########################################################################

use strict;
use warnings;

use strict;
use warnings;
use BOM::MT5::Script::StatusUpdate;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'debug';

my $verification_status = BOM::MT5::Script::StatusUpdate->new;
$verification_status->check_poa_issuance;
$verification_status->grace_period_actions;
$verification_status->disable_users_actions;
$verification_status->sync_status_actions;
