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
for my $iteration (1..10) {
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
cmp_ok($avg, '>', 28, 'average time was high enough');
cmp_ok($avg, '<', 37, 'average time was low enough');

done_testing();

