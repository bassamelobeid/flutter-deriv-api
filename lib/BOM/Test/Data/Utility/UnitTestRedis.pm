package BOM::Test::Data::Utility::UnitTestRedis;

use strict;
use warnings;

use BOM::Test;
use Dir::Self;
use Cwd qw/abs_path/;

use base qw( Exporter );
use Quant::Framework::Underlying;
use BOM::Config;
use BOM::Config::Redis;
use BOM::Config::RedisTransactionLimits;
use BOM::Test::Data::Utility::FeedTestDatabase;

our @EXPORT_OK = qw(initialize_realtime_ticks_db initialize_events_redis initialize_user_transfer_limits);

sub initialize_realtime_ticks_db {
    my $dir_path      = __DIR__;
    my $test_data_dir = abs_path("$dir_path/../../../../../data");

    my %ticks = %{YAML::XS::LoadFile($test_data_dir . '/test_realtime_ticks.yml')};

    for my $symbol (keys %ticks) {
        $ticks{$symbol}->{epoch}      = time + 600;
        $ticks{$symbol}->{underlying} = $symbol;
        BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick($ticks{$symbol});
    }

    return;
}

=head2 initialize_events_redis

Empties all queues in the test bom-events redis instance. This sub needs to be updated if new queues are added.

=cut

sub initialize_events_redis {
    my $redis = BOM::Config::Redis::redis_events_write();
    $redis->del($_) for qw (GENERIC_EVENTS_QUEUE STATEMENTS_QUEUE DOCUMENT_AUTHENTICATION_QUEUE);
    return;
}

=head2 initialize_user_transfer_limits

Deletes all keys for user daily transfer limits.

=cut

sub initialize_user_transfer_limits {
    my $redis = BOM::Config::Redis::redis_replicated_write();
    $redis->del($_) for $redis->keys('USER_TRANSFERS_DAILY::*')->@*;
    return;
}

1;
