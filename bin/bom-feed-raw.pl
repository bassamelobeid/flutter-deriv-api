#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::MarketData::FeedRaw;
use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);

$0 = 'bom-feed-raw';

GetOptions(
    'd|feed-distributor=s'    => \my $feed_distributor,
    't|timeout=i'             => \my $timeout,
    'x|update-expiry-queue=i' => \my $update_expiry_queue,
    'h|help'                  => \my $help,
);

my $show_help = $help;
die <<"EOF" if ($show_help);
usage: $0 OPTIONS

These options are available:
  -d, --feed-distributor        Feed distributor host:port (default: BOM::Platform::Config::node->{feed_server}->{fqdn})
  -t, --timeout                 Exit if there were no ticks for the specified interval in seconds (default: 10)
  -h, --help                    Show this message.
EOF

# defaults
$feed_distributor //= BOM::Platform::Config::node->{feed_server}->{fqdn} . ':' . 3030;
$timeout //= 10;

my $client = BOM::MarketData::FeedRaw->new(
    feed_distributor => $feed_distributor,
    timeout          => $timeout,
);
print("Feed raw starting\n");
my $success = 1;
while ($success) {
    $success = $client->iterate;
}

print("Feed raw finished\n");
