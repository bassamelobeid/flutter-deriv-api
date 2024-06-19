#!/etc/rmg/bin/perl

use strict;
use warnings;

=head1 NAME
bom-feed-client.pl - Clients to feed
=head1 DESCRIPTION
Parent script for all the feed plugins
=cut

use BOM::FeedPlugin::Script::FeedClient;
use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);

use Log::Any::Adapter;

GetOptions(
    'r|source=s'                 => \(my $source                 = "master-read"),
    'c|redis-config=s'           => \(my $redis_config           = "/etc/rmg/redis-feed.yml"),
    'x|update-expiry-queue=i'    => \(my $update_expiry_queue    = 0),
    'f|update-raw-forex=i'       => \(my $update_raw_forex       = 0),
    'v|update-raw-volidx=i'      => \(my $update_raw_volidx      = 0),
    'e|fake-feed-emitter=i'      => \(my $fake_feed_emitter      = 0),
    'm|accumulator-stat-chart=i' => \(my $accumulator_stat_chart = 0),
    'a|accumulator-expiry=i'     => \(my $accumulator_expiry     = 0),
    'l|log=s'                    => \(my $log_level              = "info"),
    'h|help'                     => \my $help,
);

my $show_help = $help;
die <<"EOF" if ($show_help);

usage: $0 OPTIONS

These options are available:
  -d, --distributor-redis             Choose the distributor source that the client will be subscribing to. (default: feed)
  -r, --redis-access-type             Choose distributor redis access type that will be used. (default: master-read)
  -c, --redis-config                  Choose redis configuration file (default: /etc/rmg/redis-feed.yml)
  -x, --update-expiry-queue=i         Should the expiry queue be updated or not (default: 0)
  -f, --update-raw-forex=i            Should datadecimate feed-raw forex updated or not (default: 0)
  -v, --update-raw-volidx=i           Should datadecimate feed-raw volidx updated or not (default: 0)
  -e, --fake-feed-emitter=i           Should Fake feed emitter be enabled or not (default:0)
  -s, --step-index-feed-generator=i   Should Step Index feed generator be enabled or not (default:0)
  -m, --accumulator-stat-chart=i      Should accumulator_stat_chart be enabled or not (default:0)
  -a, --accumulator-expiry=i          Should accumulator_expiry be enabled or not (default:0)
  -l, --log LEVEL                     Set the Log::Any logging level
  -h, --help                          Show this message.
EOF

Log::Any::Adapter->import(
    qw(DERIV),
    stderr    => 'json',
    log_level => $log_level
);

my $args = {
    source                 => $source,
    redis_config           => $redis_config,
    update_expiry_queue    => $update_expiry_queue,
    update_raw_forex       => $update_raw_forex,
    update_raw_volidx      => $update_raw_volidx,
    fake_feed_emitter      => $fake_feed_emitter,
    accumulator_stat_chart => $accumulator_stat_chart,
    accumulator_expiry     => $accumulator_expiry
};

exit BOM::FeedPlugin::Script::FeedClient::run($args);

