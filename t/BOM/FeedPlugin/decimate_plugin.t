use strict;
use warnings;

use Test::Most;
# The END block does not play well with forks
use Test::Warnings qw(:no_end_test had_no_warnings);
use Test::Trap;

use BOM::Config::Runtime;
use Cache::RedisDB;
use BOM::FeedPlugin::Client;
use BOM::FeedPlugin::Plugin::DataDecimate;
use BOM::Market::DataDecimate;
use File::Slurp;
use File::Temp;
use YAML::XS 0.35;
use Encode;
use JSON::MaybeUTF8 qw(:v1);
use BOM::Config::Redis;
use IO::Async::Loop;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

BOM::Config::Runtime->instance->app_config;

# Test on different market, because of the difference on BOM::Market::DataDecimate

subtest "Plugins Flow for synthetics", \&test_plugin_flow,
    {
    name   => 'R_100',
    market => 'synthetic_index'
    };

subtest "Plugins Flow for financials", \&test_plugin_flow,
    {
    name   => 'frxUSDJPY',
    market => 'forex'
    };

sub test_plugin_flow {
    my $sym = shift;

    BOM::Config::Redis::redis_feed_write()->del("QUOTE::$sym->{name}");
    is(BOM::Config::Redis::redis_feed()->get("QUOTE::$sym->{name}"), undef, "No realtime for $sym->{name}");

    my $loop   = IO::Async::Loop->new;
    my $client = BOM::FeedPlugin::Client->new(
        source       => 'master-read',
        redis_config => '/etc/rmg/redis-feed.yml'
    );
    $loop->add($client);

    push $client->plugins->@*, BOM::FeedPlugin::Plugin::DataDecimate->new(market => $sym->{market});
    $client->run->retain;

    note "DataDecimate plugin testing";
    my $time           = time;
    my $published_tick = {
        epoch  => $time,
        symbol => $sym->{name},
        quote  => '8.8888',
        bid    => '8.8887',
        ask    => '8.8889',
        market => $sym->{market},
    };

    my $attempts      = 0;
    my $plugins_timer = IO::Async::Timer::Periodic->new(
        # give some time for feed-client to process the tick
        interval => 1,
        on_tick  => sub {
            $attempts += 1;
            my $decimate_cache = BOM::Market::DataDecimate->new({
                raw_retention_interval => Time::Duration::Concise->new(interval => '31m'),
            });
            my $data_out = $decimate_cache->_get_raw_from_cache({
                symbol      => $sym->{name},
                start_epoch => $time,
                end_epoch   => $time + 1,
            });

            # Note: As long as TickEngine service is up, this test fails in QA
            # Because DataDecimate will also return the current real decimated tick
            eq_or_diff $data_out, [{%$published_tick, count => 1}],
                'Feed raw realtime was updated - DataDecimate plugin is ok (This test will fail in QA as long as TickEngine is running)';
            $loop->stop;
        },
    );

    my $publish_timer = IO::Async::Timer::Countdown->new(
        delay     => 0.1,
        on_expire => sub {
            BOM::Config::Redis::redis_feed_master_write()
                ->publish("TICK_ENGINE::$sym->{name}", encode_json_utf8($published_tick), RedisDB::IGNORE_REPLY);
            $plugins_timer->start;
        });

    $publish_timer->start;
    $loop->add($plugins_timer);
    $loop->add($publish_timer);

    $loop->run;
}

had_no_warnings();
done_testing;

1;

