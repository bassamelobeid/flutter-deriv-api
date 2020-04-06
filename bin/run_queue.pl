#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use BOM::Event::Listener;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

GetOptions(
    'q|queue=s'  => \my $queue,
) or die;

$queue        ||= 'GENERIC_EVENTS_QUEUE';

use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'info';

BOM::Event::Listener->new(queue => $queue)->run;
