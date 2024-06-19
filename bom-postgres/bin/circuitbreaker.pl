#!/etc/rmg/bin/perl

use strict;
use warnings;
use BOM::Database::Script::CircuitBreaker;
use Log::Any::Adapter 'DERIV', log_level => 'info';

BOM::Database::Script::CircuitBreaker->new(@ARGV)->run();

# TODO set perl5lib in chef
