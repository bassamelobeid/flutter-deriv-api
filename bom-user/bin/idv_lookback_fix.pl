#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;

use BOM::User::Script::IDVLookbackFix;
use Log::Any::Adapter;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

Log::Any::Adapter->import(
    qw(DERIV),
    log_level => $ENV{BOM_LOG_LEVEL} // 'info',
);

=head1 NAME

idv_lookback_fix.pl

=head1 DESCRIPTION

Meant to be executed once to correct the database data regarding IDV age verification status.

=cut 

BOM::User::Script::IDVLookbackFix::run();
