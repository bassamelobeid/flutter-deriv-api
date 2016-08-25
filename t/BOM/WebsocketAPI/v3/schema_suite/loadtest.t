use strict;
use warnings;
use Test::Most;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use Suite;

use Time::HiRes qw(tv_interval gettimeofday);
use List::Util qw(min max sum);
# TODO Flag any warnings during initial development - note that this should be handled at
# prove level as per other repos, see https://github.com/regentmarkets/bom-rpc/pull/435 for example
use Test::FailWarnings;

my @times;
for my $iteration (1 .. 10) {
    # Suite->run is likely to set the system date. Rely on the HW clock to give us times, if possible.
    system(qw(sudo hwclock --systohc)) and die "Failed to sync HW clock to system - $!";
    my $t0      = [gettimeofday];
    my $elapsed = Suite->run('loadtest.conf');
    system(qw(sudo hwclock --hctosys)) and die "Failed to sync system clock to HW - $!";
    my $wallclock = tv_interval($t0, [gettimeofday]);
    diag "Took $wallclock seconds wallclock time for loadtest including setup, $elapsed seconds cumulative step time";
    push @times, $elapsed;
}

my $min = min(@times);
my $avg = sum(@times) / @times;
my $max = max(@times);
diag sprintf "min/avg/max - %.3fs/%.3fs/%.3fs", $min, $avg, $max;

cmp_ok($avg, '>=', 12, 'average time was above the lower limit, i.e. tests are not suspiciously fast');
cmp_ok($avg, '<=', 21, 'average time was below our upper limit, i.e. we think overall test time has not increased to a dangerously high level');

done_testing();

