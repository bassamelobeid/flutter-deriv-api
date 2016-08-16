use strict;
use warnings;
use Test::Most;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use Suite;

use Time::HiRes qw(tv_interval gettimeofday);
use List::Util qw(min max sum);

my @times;
for my $iteration (1..2) {
	my $t0 = [gettimeofday];
	Suite->run('loadtest.conf');
	my $elapsed = tv_interval( $t0, [gettimeofday]);
	diag "Took $elapsed seconds for loadtest";
	push @times, $elapsed;
}

my $min = min(@times);
my $avg = sum(@times)/@times;
my $max = max(@times);
diag sprintf "min/avg/max - %.3fs/%.3fs/%.3fs", $min, $avg, $max;
cmp_ok($avg, '>', 60, 'average time was at least 60s');
cmp_ok($avg, '<', 120, 'average time was less than 120s');

done_testing();

