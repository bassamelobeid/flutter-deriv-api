use strict;
use warnings;
use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use Mojo::Redis2;
use Data::Dumper;

my $ws_redis_write_config = YAML::XS::LoadFile('/etc/rmg/ws-redis.yml')->{write};

my $ws_redis_write_url = do {
    my ($host, $port, $password) = @{$ws_redis_write_config}{qw/host port password/};
    "redis://" . (defined $password ? "dummy:$password\@" : "") . "$host:$port";
};

my $shared_info  = {};
my $channel_name = "NOTIFY::broadcast::channel";
my $state_key    = "NOTIFY::broadcast::state";
my $is_on_key    = "NOTIFY::broadcast::is_on";     ### TODO: to config

### Blue master
my $redis = Mojo::Redis2->new(url => $ws_redis_write_url);
$redis->on(
    error => sub {
        my ($self, $err) = @_;
        warn "ws write redis error: $err";
    });
$redis->on(
    message => sub {
        my ($self, $msg, $channel) = @_;

        Binary::WebSocketAPI::v3::Wrapper::Streamer::send_notification($shared_info, $msg, $channel);
    });
is($redis->set($is_on_key, 1), 'OK');
my $t = build_wsapi_test(
    {},
    {},
    sub {
        my ($self, $mess) = @_;
        test_schema("broadcast_notifications", $mess);
    });

$t = $t->send_ok({json => {broadcast_notifications => 1}})->message_ok;

$shared_info->{echo_req} = {broadcast_notifications => 1};
$shared_info->{c} = $t;
my $pid = fork;

die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    sleep 5;
    for (1 .. 2) {
        $redis->publish($channel_name => '{"site_status": "up", "message": "Unit test $_"}');
        sleep 1;
    }
    exit;
}
sleep 10;
$t->finish_ok();

done_testing();
