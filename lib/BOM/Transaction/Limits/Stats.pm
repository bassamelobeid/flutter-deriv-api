package BOM::Transaction::Limits::Stats;
use strict;
use warnings;

use Time::HiRes qw(tv_interval gettimeofday);
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing stats_count);
use BOM::Config;

# Contains all code that compiles statistical data about company limits and
# contracts that is coming in this system, and shipping that info to datadog.

sub with_dd_stats (&@) {
    my ($sub, $what, $landing_company, $virtual) = @_;

    my $start = [gettimeofday];

    my (@res, $no_ex);
    if (wantarray) {
        $no_ex = eval { @res = $sub->(); 1; };
    } elsif (defined wantarray) {
        $no_ex = eval { $res[0] = $sub->(); 1; };
    } else {
        $no_ex = eval { $sub->(); 1; };
    }

    $virtual = $virtual ? 'yes' : 'no';

    if ($no_ex) {
        stats_timing(
            "companylimits.$what.elapsed_time",
            1000 * tv_interval($start, [gettimeofday]),
            {tags => ["virtual:$virtual",
                      "rmgenv:" . BOM::Config::env,
                      "landing_company:$landing_company"]});
    } else {
        stats_timing(
            "companylimits.$what.failed.elapsed_time",
            1000 * tv_interval($start, [gettimeofday]),
            {tags => ["virtual:$virtual",
                      "rmgenv:" . BOM::Config::env,
                      "landing_company:$landing_company"]});

        die $@;
    }

    return @res;
}

1;
