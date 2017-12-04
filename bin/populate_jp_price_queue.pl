#!/usr/bin/env perl 
use strict;
use warnings;

use feature qw(say);

# load this file to force MOJO::JSON to use JSON::MaybeXS
use MOJO::JSON::MaybeXS;
use Log::Any::Adapter qw(Stderr), log_level => 'info';
use BOM::Pricing::QueuePopulator::Japan;

exit BOM::Pricing::QueuePopulator::Japan->new->run;

