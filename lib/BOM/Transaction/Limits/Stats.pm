package BOM::Transaction::Limits::Stats;
use strict;
use warnings;

use Time::HiRes qw(tv_interval gettimeofday time);
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing stats_count);
use BOM::Config;

# Contains all code that compiles statistical data about company limits and
# contracts that is coming in this system, and shipping that info to datadog.

sub stats_start {
    my ($company_limits, $what) = @_;
    my $landing_company = $company_limits->{landing_company};

    my $virtual = $landing_company eq 'virtual' ? 'yes' : 'no';
    my $rmgenv  = BOM::Config::env;
    my $tags    = {tags => ["virtual:$virtual", "rmgenv:$rmgenv", "landing_company:$landing_company"]};

    return +{
        start   => [gettimeofday],
        tags    => $tags,
        virtual => $virtual,
        rmgenv  => $rmgenv,
        what    => $what,
    };
}

sub stats_stop {
    my ($data) = @_;

    my $what = $data->{what};
    my $tags = $data->{tags};

    my $now = [gettimeofday];
    stats_timing("companylimits.$what.elapsed_time", 1000 * tv_interval($data->{start}, $now), $tags);

    return;
}

1;

