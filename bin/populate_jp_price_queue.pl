#!/usr/bin/env perl 
use strict;
use warnings;

use feature qw(say);

use Log::Any::Adapter qw(Stderr), log_level => 'info';
use BOM::Pricing::QueuePopulator::Japan;

exit BOM::Pricing::QueuePopulator::Japan->new->run;

