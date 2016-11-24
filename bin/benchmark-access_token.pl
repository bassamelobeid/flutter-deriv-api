#!/etc/rmg/bin/perl

use strict;
use warnings;
use BOM::Database::Model::OAuth;
use Time::HiRes ();

my ($token, $req, $fork) = @ARGV;

$req //= 50_000;
$fork //= 10;

sub hist {
    my @times = sort {$a<=>$b} @_;
    my $dist = ($times[-1] - $times[0]) / 10;

    my @hist;
    my $curr = 0;
    my $lim = $dist;
    for (@times) {
	$lim += $dist, $curr++ while $_ > $lim;
	$hist[$curr]++;
    }
    return sprintf 'min=%.3f max=%.3f hist=(%s)', $times[0], $times[-1], join(',', @hist);
}

sub doit {
    my $m=BOM::Database::Model::OAuth->new;
    my $stmp = Time::HiRes::time;
    my $start = $stmp;

    my @times;

    while ($req--) {
	$m->get_loginid_by_access_token($token);
	my $now = Time::HiRes::time;
	push @times, ($now-$stmp)*1000;
	$stmp = $now;
    }
    my $end = Time::HiRes::time;

    printf "Child $$: %.3f sec %s\n", $end - $start, hist(@times);
}

my (@pids, $pid);

for (1..$fork) {
    select undef, undef, undef, 0.1 until (defined ($pid=fork));
    if ($pid) {			# parent
	push @pids, $pid;
    } else {			# child
	@pids=();
	doit;
	exit 0;
    }
}

my $stmp = Time::HiRes::time;
waitpid $_, 0 for @pids;
printf "Parent: %.3f sec\n", Time::HiRes::time - $stmp;
