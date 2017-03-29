#!/usr/bin/env perl 
use strict;
use warnings;

use BOM::Pricing::QueuePopulator::Japan;
use feature qw(say);

exit BOM::Pricing::QueuePopulator::Japan->new->run;

