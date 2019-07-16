#!/usr/bin/env perl
use strict;
use warnings;
use BOM::Event::Listener;

use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'info';

BOM::Event::Listener->new(queue => 'GENERIC_EVENTS_QUEUE')->run;
