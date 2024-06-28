package BOM::FeedPlugin::Script::FeedClient;
use strict;
use warnings;
no indirect;

use Syntax::Keyword::Try;
use BOM::FeedPlugin::Client;
use BOM::FeedPlugin::Plugin::ExpiryQueue;
use BOM::FeedPlugin::Plugin::FakeEmitter;
use BOM::FeedPlugin::Plugin::AccumulatorStatChart;
use BOM::FeedPlugin::Plugin::AccumulatorExpiry;
use Time::HiRes                ();
use List::Util                 qw(min);
use DataDog::DogStatsd::Helper qw(stats_timing);
use Log::Any                   qw($log);
use IO::Async::Loop;

sub run {
    my $args = shift;

    my $source                 = $args->{source};
    my $redis_config           = $args->{redis_config};
    my $update_expiry_queue    = $args->{update_expiry_queue};
    my $fake_feed_emitter      = $args->{fake_feed_emitter};
    my $accumulator_stat_chart = $args->{accumulator_stat_chart};
    my $accumulator_expiry     = $args->{accumulator_expiry};

    STDOUT->autoflush(1);

    try {
        $log->infof("Feed-Client starting, now = %s", time);
        my $loop   = IO::Async::Loop->new;
        my $client = BOM::FeedPlugin::Client->new(
            source       => $source,
            redis_config => $redis_config,
        );
        $loop->add($client);
        push $client->plugins->@*, BOM::FeedPlugin::Plugin::ExpiryQueue->new()          if $update_expiry_queue;
        push $client->plugins->@*, BOM::FeedPlugin::Plugin::FakeEmitter->new()          if $fake_feed_emitter;
        push $client->plugins->@*, BOM::FeedPlugin::Plugin::AccumulatorStatChart->new() if $accumulator_stat_chart;
        push $client->plugins->@*, BOM::FeedPlugin::Plugin::AccumulatorExpiry->new()    if $accumulator_expiry;
        $log->infof("Plugins Enabled: %s", $client->plugins_running);
        $client->run->get;

        $log->infof("Feed-Client finished. Now = %s", time);
    } catch ($e) {
        $log->errorf("Feed-Client error:: %s, now = %s", $e, time);
    }
    return 1;
}

1;
