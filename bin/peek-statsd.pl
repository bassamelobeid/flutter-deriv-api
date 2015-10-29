#!/usr/bin/perl

use 5.014;
use strict;
use warnings;

use Socket;
use IO::Socket::INET;
use Getopt::Long;

my @opt_m;
my @opt_t;
my $opt_h;

if (
    !GetOptions(
        'measure=s' => \@opt_m,
        'tag=s'     => \@opt_t,
        'help!'     => \$opt_h
    )
    or $opt_h
    )
{
    print STDERR <<'EOF';
Usage: peek-statsd.pl [-measure=regexp ...] [-tag=regexp ...] [-help]
EOF
    exit !$opt_h;
}

my $s = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1:8125',
    Proto     => 'udp',
    Type      => SOCK_DGRAM,
);

my $buf;
while () {
    my $addr = $s->recv($buf = '', 8192, 0);
    if (defined $addr) {
        (my $port, $addr) = unpack_sockaddr_in $addr;
        my ($m, $t, @l) = split /\|/, $buf;
        ($m, my $d) = split /:/, $m;
        my $rate = '';
        my @tags;
        for (@l) {
            if (s/^@//) {
                $rate = $_;
            } elsif (s/^#//) {
                @tags = split /,/;
            }
        }
        if (@opt_m + @opt_t) {
            my $print = 0;
            for my $re (@opt_m) {
                if ($m =~ $re) {
                    $print = 1;
                    last;
                }
            }
            unless ($print) {
                OUTER:
                for my $t (@tags) {
                    for my $re (@opt_t) {
                        if ($t =~ $re) {
                            $print = 1;
                            last OUTER;
                        }
                    }
                }
            }
            next unless $print;
        }
        printf "%vd:%d: measure=%s, delta=%s, type=%s, rate=%s, tags=%s\n", $addr, $port, $m, $d, $t, $rate, join(' ', @tags);
    } else {
        select undef, undef, undef, .2;    # error: sleep for a while
    }
}
