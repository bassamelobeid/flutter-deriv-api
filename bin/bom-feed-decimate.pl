#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::MarketData qw(create_underlying);
use BOM::MarketData qw(create_underlying_db);

use BOM::Market::DecimateCache;

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

my $decimate_cache = BOM::Market::DecimateCache->new();

my @uls = map { create_underlying($_) } create_underlying_db->symbols_for_intraday_fx;

my $now               = int time;
my $hold_time         = 1;
my $decimate_interval = $decimate_cache->sampling_frequency->seconds;
my $boundary          = $now - ($now % $decimate_interval) + ($decimate_interval);
my $next_start        = $boundary + $hold_time;

while (1) {

    my $sleep = max(0, $next_start - time);
    sleep($sleep);
    my $fill_poch = $next_start - $hold_time;
    $boundary   = $boundary + $decimate_interval;
    $next_start = $boundary + $hold_time;

    foreach my $ul (@uls) {
        $decimate_cache->data_cache_insert_decimate($ul->symbol, $boundary);
    }
}

print("Feed decimate finished\n");
