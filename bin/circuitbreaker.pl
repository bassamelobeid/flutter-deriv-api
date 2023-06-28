#!/etc/rmg/bin/perl

use strict;
use warnings;
use BOM::Database::Script::CircuitBreaker;
use Log::Any::Adapter 'DERIV', log_level => 'info';

=head1 NAME

circuitbreaker

=head1 SYNOPSIS

bin/circuitbreaker.pl

=head1 More info

please read POD of BOM::Database::Script::CircuitBreaker

=cut

BOM::Database::Script::CircuitBreaker->new(@ARGV)->run();

