#!/usr/bin/env perl
use strict;
use warnings;

use IO::Async::Loop;
use IO::Async::Process;

# usage:
#   perl submit-one.pl RPCNAME ARG1 ARG2
#
# examples:
#
# $ perl submit-one.pl ping HOLA
# $ Response: "HOLA"

my $name = shift @ARGV;

my $loop    = IO::Async::Loop->new;
my $process = IO::Async::Process->new(
    command => ["redis-cli", $name, @ARGV],
    stdout  => {
        on_read => sub {
            my ($stream, $buffref) = @_;
            while ($$buffref =~ s/^(.*)\n//) {
                print "Response: '$1'\n";
            }
            return 0;
        },
    },
    on_finish => sub {
        $loop->stop;
    },
);

$loop->add($process);
$loop->run;
