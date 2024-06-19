use strict;
use warnings;
use Test::More;
use BOM::Test::Helper                qw/build_wsapi_test/;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
use JSON::MaybeUTF8                  qw/decode_json_utf8/;
use Encode 'encode';
# we need this because of calculating max exchange rates on currency config
populate_exchange_rates();

#should be mocked before building wsapi test
my $redis_pub = mock_redis('ws_redis_master');

my $t = build_wsapi_test();

subtest "website status by default is up" => sub {
    $t = $t->send_ok({json => {website_status => 1}})->message_ok;
    my $res = decode_json_utf8($t->message->[1]);
    is site_status($res), 'up', 'site status is up';
};

subtest 'close the gate' => sub {
    $t = $t->send_ok({json => {website_status => 1, subscribe => 1}})->message_ok;
    my $res = decode_json_utf8($t->message->[1]);
    update_status('down');

    subtest 'new site status communicated to subscribers' => sub {
        my $status = wait_for_message($t);
        is site_status($status), 'down', 'site status is down';
    };

    subtest 'ping and website status still reachable' => sub {
        $t = $t->send_ok({json => {ping => 1}})->message_ok;
        #Mojo::IOLoop->start;
        my $res = decode_json_utf8($t->message->[1]);
        is $res->{ping}, 'pong', 'ping is pong';
        $t   = $t->send_ok({json => {website_status => 1}})->message_ok;
        $res = decode_json_utf8($t->message->[1]);
        is site_status($res), 'down', 'site status is down';
    };

    subtest 'Other calls activates the circuit' => sub {
        $t = $t->send_ok({json => {time => 1}})->message_ok;
        my $res = decode_json_utf8($t->message->[1]);
        is $res->{error}->{code}, 'ServiceUnavailable', 'Received Circuit Breaker error';
    };
};

subtest 'open the gate' => sub {
    $t = build_wsapi_test();
    subtest 'website status is down' => sub {
        $t = $t->send_ok({json => {website_status => 1,}})->message_ok;
        my $res = decode_json_utf8($t->message->[1]);
        is site_status($res), 'down', 'site status is down after new connection';
    };

    update_status('up');
    Mojo::IOLoop->one_tick;
    subtest 'website status is up' => sub {
        $t = $t->send_ok({json => {website_status => 1,}})->message_ok;
        my $res = decode_json_utf8($t->message->[1]);
        is site_status($res), 'up', 'site status is up after update';
    };

    subtest 'Other calls can proceed' => sub {
        $t = $t->send_ok({json => {time => 1}})->message_ok;
        my $res = decode_json_utf8($t->message->[1]);
        ok $res->{time}, 'Received Circuit Breaker error';
    };

};

sub update_status {
    my $status  = shift;
    my $message = sprintf('{"site_status": "%s", "message": "suspended"}', $status);
    $redis_pub->set('NOTIFY::broadcast::state', $message);
    $redis_pub->set("NOTIFY::broadcast::is_on", 1);
    my $res = $redis_pub->publish("NOTIFY::broadcast::channel" => $message);
}

=head2 wait_for_message

Because the Mojo::Test manages the event loop, we need to wait for the message to be received the same way. 
Such messages are resulted from a background process like subscription (i.e $redis->on(message => sub { ... })).

=cut

sub wait_for_message {
    my $t = shift;
    $t = $t->message_ok;
    my $message = $t->message->[1];
    return decode_json_utf8(encode('UTF-8', $message));
}

=head2 mock_redis

Creates a new Test Redis server.
then mocks the Redis instance with the given name and return a Mojo::Redis2 connected to the new test server.

=cut

my @redis_servers;

sub mock_redis {
    my $redis_instance = shift;
    my $redis_server   = Mojo::Redis2::Server->new;
    $redis_server->start(
        save       => ' ',    # disable snapshotting and don't save data to disk db.
        appendonly => 'no'
    );
    my $redis_port = $redis_server->url =~ s/.*:(\d+).*/$1/r;
    my $redis      = Mojo::Redis2->new(url => "redis://localhost:$redis_port");
    diag "Testing Redis server for $redis_instance started on port: " . $redis_server->url;
    my $mock_redis_instance = Test::MockModule->new('Binary::WebSocketAPI::v3::Instance::Redis');
    $mock_redis_instance->mock(
        create => sub {
            my ($name) = @_;
            if ($name eq $redis_instance) {
                return $redis;
            } else {
                return $mock_redis_instance->original('create')->(@_);
            }
        });
    push @redis_servers, $redis_server;
    return $redis;
}

sub site_status {
    return shift->{website_status}->{site_status};
}

sub stop_servers {
    for my $server (@redis_servers) {
        $server->stop;
    }
}

stop_servers();    # not really needed, but just in case.
done_testing();
