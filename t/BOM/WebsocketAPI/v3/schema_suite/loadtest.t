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
cmp_ok($avg, '>', 20, 'average time was above the lower limit, i.e. tests are not suspiciously fast');
cmp_ok($avg, '<', 35, 'average time was below our upper limit, i.e. we think overall test time has not increased to a dangerously high level');

done_testing();

