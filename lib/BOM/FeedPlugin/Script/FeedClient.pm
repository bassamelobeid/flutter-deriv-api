package BOM::FeedPlugin::Script::FeedClient;
use strict;
use warnings;
no indirect;

use Syntax::Keyword::Try;
use BOM::FeedPlugin::Client;
use BOM::FeedPlugin::Plugin::ExpiryQueue;
use BOM::FeedPlugin::Plugin::DataDecimate;
use BOM::FeedPlugin::Plugin::FakeEmitter;
use BOM::FeedPlugin::Plugin::AccumulatorStatChart;
use BOM::FeedPlugin::Plugin::AccumulatorExpiry;
use Getopt::Long               qw(GetOptions :config no_auto_abbrev no_ignore_case);
use Time::HiRes                ();
use List::Util                 qw(min);
use DataDog::DogStatsd::Helper qw(stats_timing);
use Log::Any                   qw($log);
use IO::Async::Loop;

sub run {
    STDOUT->autoflush(1);

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

    # We use Log::Any::Adapter here because this module is the entrance of the whole program.
    require Log::Any::Adapter;
    Log::Any::Adapter->import(
        qw(DERIV),
        stderr    => 'json',
        log_level => $log_level
    );

    try {
        $log->infof("Feed-Client starting, now = %s", time);
        my $loop   = IO::Async::Loop->new;
        my $client = BOM::FeedPlugin::Client->new(
            source       => $source,
            redis_config => $redis_config,
        );
        $loop->add($client);
        push $client->plugins->@*, BOM::FeedPlugin::Plugin::ExpiryQueue->new()                             if $update_expiry_queue;
        push $client->plugins->@*, BOM::FeedPlugin::Plugin::DataDecimate->new(market => 'forex')           if $update_raw_forex;
        push $client->plugins->@*, BOM::FeedPlugin::Plugin::DataDecimate->new(market => 'synthetic_index') if $update_raw_volidx;
        push $client->plugins->@*, BOM::FeedPlugin::Plugin::FakeEmitter->new()                             if $fake_feed_emitter;
        push $client->plugins->@*, BOM::FeedPlugin::Plugin::AccumulatorStatChart->new()                    if $accumulator_stat_chart;
        push $client->plugins->@*, BOM::FeedPlugin::Plugin::AccumulatorExpiry->new()                       if $accumulator_expiry;
        $log->infof("Plugins Enabled: %s", $client->plugins_running);
        $client->run->get;

        $log->infof("Feed-Client finished. Now = %s", time);
    } catch ($e) {
        $log->errorf("Feed-Client error:: %s, now = %s", $e, time);
    }
    return 1;
}

1;
