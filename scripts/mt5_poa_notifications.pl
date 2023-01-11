#!/usr/bin/perl

#########################################################################
# mt5_poa_notifications                                                 #
# This script is used inform clients via email about their poa status   #
#########################################################################

use strict;
use warnings;
use BOM::MT5::Script::StatusUpdate;

my $verification_status = BOM::MT5::Script::StatusUpdate->new;
$verification_status->send_warning_emails;
$verification_status->send_reminder_emails;
