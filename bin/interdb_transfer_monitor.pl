#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long;
use Log::Any::Adapter;
use BOM::User::Script::InterDBTransferMonitor;

GetOptions(
    'l|log=s'         => \my $log_level,
    'json_log_file=s' => \my $json_log_file,
) or die;

Log::Any::Adapter->import(
    qw(DERIV),
    log_level => $log_level || 'info',
    $json_log_file ? (json_log_file => $json_log_file) : (),
);

exit BOM::User::Script::InterDBTransferMonitor->new->run;
