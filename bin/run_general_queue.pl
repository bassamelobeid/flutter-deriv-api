#!/usr/bin/env perl
use strict;
use warnings;

use Log::Any::Adapter qw(Stderr), log_level => 'info';

use BOM::Event::Listener;

BOM::Event::Listener->run('GENERIC_EVENTS_QUEUE');
