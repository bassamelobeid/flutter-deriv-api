package BOM::Test::Data::Utility::UnitTestRedis;

use strict;
use warnings;

use Dir::Self;
use Cwd qw/abs_path/;

use base qw( Exporter );
use Quant::Framework::Underlying;
use BOM::Test;
use BOM::Config::RedisReplicated;

our @EXPORT_OK = qw(initialize_realtime_ticks_db initialize_events_redis);

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

sub initialize_realtime_ticks_db {
    my $dir_path      = __DIR__;
    my $test_data_dir = abs_path("$dir_path/../../../../../data");

    my %ticks = %{YAML::XS::LoadFile($test_data_dir . '/test_realtime_ticks.yml')};

    for my $symbol (keys %ticks) {
        my $args = {};
        $args->{symbol}           = $symbol;
        $args->{chronicle_reader} = BOM::Config::Chronicle::get_chronicle_reader();
        $args->{chronicle_writer} = BOM::Config::Chronicle::get_chronicle_writer();

        my $ul = Quant::Framework::Underlying->new($args);

        $ticks{$symbol}->{epoch} = time + 600;
        $ul->set_combined_realtime($ticks{$symbol});
    }

    return;
}

=head2 initialize_events_redis

Empties all queues in the test bom-events redis instance (using config at $ENV{BOM_TEST_REDIS_REPLICATED}
because BOM::Test is included above). This sub needs to be updated if new queues are added.

=cut

sub initialize_events_redis {
    my $redis = BOM::Config::RedisReplicated::redis_events_write();
    $redis->del($_) for qw (GENERIC_EVENTS_QUEUE STATEMENTS_QUEUE DOCUMENT_AUTHENTICATION_QUEUE);
    return;
}

1;
