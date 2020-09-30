package BOM::Market::Script::FeedDecimate;
use strict;
use warnings;

use BOM::MarketData qw(create_underlying);
use BOM::MarketData qw(create_underlying_db);

use BOM::Market::DataDecimate;

use List::Util qw(first max);
use Data::Decimate qw(decimate);

use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);

sub run {
    local $0 = 'bom-feed-decimate';

    GetOptions(
        'h|help' => \my $help,
    );

    my $show_help = $help;
    die <<"EOF" if ($show_help);
usage: $0 OPTIONS

These options are available:
  -h, --help                    Show this message.
EOF

    print("Feed decimate starting\n");

    my $decimate_cache = BOM::Market::DataDecimate->new(market => 'forex');

    my @uls = map { create_underlying($_) } create_underlying_db->symbols_for_intraday_fx(1);

    # back populate
    my $interval = $decimate_cache->sampling_frequency->seconds;

    my $end   = time;
    my $start = $end - $decimate_cache->decimate_retention_interval->seconds;
    $start = $start - ($start % $interval) - $interval;

    $end = $end - ($end % $interval);

    foreach my $ul (@uls) {

        my $last_non_zero_decimated_tick = $decimate_cache->get_latest_tick_epoch($ul->symbol, 1, $start, $end);
        my $last_decimate_epoch          = max($start, $last_non_zero_decimated_tick + 1);

        # If we restart the service when this service is
        # already running the start date will be after the end date
        # this check will ignore this cases and they will be
        # verified in the next run.
        next if $last_decimate_epoch > $end;

        my $ticks = $ul->ticks_in_between_start_end({
            start_time => $last_decimate_epoch,
            end_time   => $end,
        });

        $decimate_cache->data_cache_back_populate_decimate($ul->symbol, $ticks);
    }

    print "Decimating realtime data...\n";

    my $now               = int time;
    my $hold_time         = 1;
    my $decimate_interval = $decimate_cache->sampling_frequency->seconds;
    my $boundary          = $now - ($now % $decimate_interval) + ($decimate_interval);
    my $next_start        = $boundary + $hold_time;

    while (1) {

        my $sleep = max(0, $next_start - time);
        sleep($sleep);

        foreach my $ul (@uls) {
            $decimate_cache->data_cache_insert_decimate($ul->symbol, $boundary);
        }

        $boundary   = $boundary + $decimate_interval;
        $next_start = $boundary + $hold_time;
    }

    print("Feed decimate finished\n");
    return;
}

1;
