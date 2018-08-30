#!/usr/bin/env perl
use strict;
use warnings;

use BOM::Event::Listener;

BOM::Event::Listener->run('GENERIC_EVENTS_QUEUE');
