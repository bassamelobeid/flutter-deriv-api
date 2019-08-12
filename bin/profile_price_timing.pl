#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Product::ContractFactory qw/produce_contract/;
use Time::HiRes ();

sub get_worklist {
    my @worklist;

    # @ARGV is a list of shortcode/currency pairs
    if (@ARGV) {
        while (@ARGV) {
            push @worklist, [splice(@ARGV, 0, 2), 'ask'];
        }
    } else {
        while (defined (my $l=readline STDIN)) {
            chomp $l;
            push @worklist, [split /\s+/, $l, 3];
        }
    }

    return \@worklist;
}

sub one {
    my $item = shift;
    my $m = $item->[2] . '_price';
    return eval {produce_contract(@{$item}[0,1])->$m };
}

sub warm_up {
    my $worklist = shift;

    foreach my $item (@$worklist) {
        one $item;
    }
}

sub sorted {
    my $worklist = shift;

    my @unable;
    my $p;
    foreach my $item (@$worklist) {
        my $start = [Time::HiRes::gettimeofday];
        $p = one $item for (1..10);
        push @$item, defined($p) ? 100 * Time::HiRes::tv_interval($start) : -1;
        push @unable, [@{$item}[0,1,2], $@] unless $p;
    }

    return [sort {$b->[-1] <=> $a->[-1]} @$worklist], \@unable;
}

sub profile {
    my $worklist = shift;
    my $unable = shift;
    my $howmany = shift;

    for (my $i=0; $i<$howmany; $i++) {
        my $item = $worklist->[$i];
        last unless $item and $item->[-1]>0;
        my $fn = "nytprof-$i.out";
        unlink $fn;
        print "profiling: @$item to $fn\n";
        DB::enable_profile $fn;
        one $item for (1..10);
        DB::finish_profile;
    }

    open my $html, '>', 'index.html' or die "Cannot open index.html: $!\n";
    print $html "<html><body><h1>Slowest $howmany contracts to price</h1><ul>\n";
    for (my $i=0; $i<$howmany; $i++) {
        my $item = $worklist->[$i];
        last unless $item;
        my $fn = "nytprof-$i.out";
        my $dn = join '--', @{$item}[0,1,2];
        system 'rm', '-rf', $dn;
        system 'nytprofhtml', '-f', $fn, '-o', $dn;
        system 'sed', '-i',
            's/>Performance Profile Index</>Profile for shortcode: '
            . " $item->[0] currency: $item->[1] ($item->[2])</",
            $dn . '/index.html';
        print $html qq{<li><a href="$dn/index.html">@{$item}</a></li>\n};
    }
    if (@$unable) {
        print $html "</ul><h1>Contracts that failed to price</h1><ul>\n";
        print $html qq{<li>@$_</li>\n}
            for (@$unable);
    }
    print $html "</ul></body></html>\n";

    return;
}

my $wl = get_worklist;
warm_up $wl;
profile sorted ($wl), 15;
