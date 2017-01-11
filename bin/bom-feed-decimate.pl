#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::MarketData qw(create_underlying);
use BOM::MarketData qw(create_underlying_db);

use BOM::Market::DataDecimate;

use List::Util qw(max);
use Data::Decimate qw(decimate);

use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);

$0 = 'bom-feed-decimate';

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

my $decimate_cache = BOM::Market::DataDecimate->new();

my @uls = map { create_underlying($_) } create_underlying_db->symbols_for_intraday_fx;

#back populate
my $interval = $decimate_cache->sampling_frequency->seconds;

my $end = time;
my $start = $end - (12 * 60 * 60);
$start = $start - ($start % $interval) - $interval;

foreach my $ul (@uls) {

    my $decimate_key = $decimate_cache->_make_key($ul->symbol, 1);

    my $last_non_zero_decimated_tick = do {
        my $timestamp     = 0;
        my $redis         = $decimate_cache->redis_read;
        my $earlier_ticks = $redis->zcount($decimate_key, '-inf', $start);

        if ($earlier_ticks) {
            my @ticks = map { $decimate_cache->decoder->decode($_) } @{$redis->zrevrangebyscore($decimate_key, $end, $start, 'LIMIT', 0, 100)};
            my $non_zero_tick = first { $_->{count} > 0 } @ticks;
            if ($non_zero_tick) {
                $timestamp = $non_zero_tick->{decimate_epoch};
            }
        }
        $timestamp;
    };
    my $last_decimate_epoch = max($start, $last_non_zero_decimated_tick);

    my $ticks = $ul->ticks_in_between_start_end({
        start_time => $last_decimate_epoch,
        end_time   => $end,
    });

    my @rev_ticks = reverse @$ticks;
    my $decimate_data = Data::Decimate::decimate($decimate_cache->sampling_frequency->seconds, \@rev_ticks);

    foreach my $single_data (@$decimate_data) {
        $decimate_cache->_update(
            $decimate_cache->redis_write,
            $decimate_key,
            $single_data->{decimate_epoch},
            $decimate_cache->encoder->encode($single_data));
    }
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
        $decimate_cache->clean_up($ul->symbol, $boundary);
    }

    $boundary   = $boundary + $decimate_interval;
    $next_start = $boundary + $hold_time;
}

print("Feed decimate finished\n");
