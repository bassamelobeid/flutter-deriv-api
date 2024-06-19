use Test::Most;
use Test::MockObject;
use Test::MockModule;

use JSON::MaybeUTF8 'encode_json_utf8';
use Binary::WebSocketAPI::SiteStatusMonitor;

my $mocked_redis = mock_redis();
my $site_status;

my $mocked_site_status_monitor = Test::MockModule->new('Binary::WebSocketAPI::SiteStatusMonitor');
$mocked_site_status_monitor->mock('_build_redis', sub { return $mocked_redis; });

sub mock_redis {
    my $redis = Test::MockObject->new;
    $redis->mock('on',        sub { shift; $redis->{on_handler}         = shift; });
    $redis->mock('subscribe', sub { shift; $redis->{subscribed_channel} = shift; });
    $redis->mock('get',       sub { return encoded_site_status($site_status); });
    return $redis;
}

sub encoded_site_status {
    my $status = shift;
    return encode_json_utf8({site_status => $status});
}

subtest 'Loading SiteStatusMonitor' => sub {
    my $site_status_monitor = Binary::WebSocketAPI::SiteStatusMonitor->new();
    isa_ok $site_status_monitor, 'Binary::WebSocketAPI::SiteStatusMonitor', 'SiteStatusMonitor loaded';
};

subtest 'initialize site_status' => sub {

    subtest 'initialize when NOTIFY::broadcast::state is not set' => sub {
        my $site_status_monitor = Binary::WebSocketAPI::SiteStatusMonitor->new();
        is $site_status_monitor->site_status,        'up',                         'Site status defaulted to up when no status is set';
        is $mocked_redis->{subscribed_channel}->[0], 'NOTIFY::broadcast::channel', 'Subscribed to correct channel';
        is $mocked_redis->{on_handler},              'message',                    'rigestered on message handler';
    };

    subtest 'initialize when NOTIFY::broadcast::state is set to down' => sub {
        my $site_status_monitor = Binary::WebSocketAPI::SiteStatusMonitor->new();
        $site_status = 'down';
        is $site_status_monitor->site_status,        'down',                       'Site status is down when set to down';
        is $mocked_redis->{subscribed_channel}->[0], 'NOTIFY::broadcast::channel', 'Subscribed to correct channel';
        is $mocked_redis->{on_handler},              'message',                    'rigestered on message handler';

    };

    subtest 'initialize when NOTIFY::broadcast::state is set to up' => sub {
        my $site_status_monitor = Binary::WebSocketAPI::SiteStatusMonitor->new();
        $site_status = 'up';
        is $site_status_monitor->site_status,        'up',                         'Site status is up when set to up';
        is $mocked_redis->{subscribed_channel}->[0], 'NOTIFY::broadcast::channel', 'Subscribed to correct channel';
        is $mocked_redis->{on_handler},              'message',                    'rigestered on message handler';
    };
};

subtest 'update_site_status' => sub {
    my $site_status_monitor = Binary::WebSocketAPI::SiteStatusMonitor->new();
    $site_status = 'down';
    $site_status_monitor->_update_site_status(encoded_site_status('down'));
    is $site_status_monitor->site_status, 'down', 'Site status updated to down';
    $site_status = 'up';
    $site_status_monitor->_update_site_status(encoded_site_status('up'));
    is $site_status_monitor->site_status, 'up', 'Site status updated to up';
};

subtest 'decode_site_status' => sub {
    my $site_status_monitor = Binary::WebSocketAPI::SiteStatusMonitor->new();
    is $site_status_monitor->_decode_site_status(encoded_site_status('down')), 'down', 'Site status decoded to down';
    is $site_status_monitor->_decode_site_status(encoded_site_status()),       'up',   'Site status decoded to up with undef value';
};

subtest 'build_redis' => sub {
    $mocked_site_status_monitor->unmock('_build_redis');
    my $site_status_monitor = Binary::WebSocketAPI::SiteStatusMonitor->new();
    isa_ok $site_status_monitor->redis, 'Mojo::Redis2', 'redis attribute is a mock object';
};

done_testing();
