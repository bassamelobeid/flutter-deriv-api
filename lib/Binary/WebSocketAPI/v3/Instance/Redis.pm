package Binary::WebSocketAPI::v3::Instance::Redis;

use strict;
use warnings;

=head1 NAME

Binary::WebSocketAPI::v3::Instance::Redis - manage Redis connections for websocket servers

=head1 DESCRIPTION

Provides a container for dealing with all internal Redis connections.

=cut

no indirect;
use Try::Tiny;

use YAML::XS qw(LoadFile);
use Exporter qw(import);
use DataDog::DogStatsd::Helper qw(stats_inc stats_dec);
use Mojo::Redis2;
use Scalar::Util qw(looks_like_number);

# Add entries here if a new Redis instance is available, this will then be accessible
# via a function of the same name.
my $servers = {
    shared_redis => {
        config   => '/etc/rmg/chronicle.yml',
        user     => 'read',
        override => 'BOM_TEST_REDIS_REPLICATED'
    },
    redis_transaction => {
        config   => '/etc/rmg/redis-transaction.yml',
        user     => 'read',
        override => 'BOM_TEST_REDIS_TRANSACTION'
    },
    redis_pricer => {
        config   => '/etc/rmg/redis-pricer.yml',
        user     => 'write',
        override => 'BOM_TEST_REDIS_REPLICATED'
    },
    ws_redis_master => {
        config   => '/etc/rmg/ws-redis.yml',
        user     => 'write',
        override => 'BOM_TEST_WS_REDIS'
    },
    redis_queue => {
        config   => '/etc/rmg/redis-queue.yml',
        user     => 'write',
        override => 'BOM_TEST_REDIS_QUEUE'
    }};

# We export (on demand) all Redis names and a helper function.
our @EXPORT_OK = ('check_connections', sort keys %$servers);

# Used to cache the singletons.
our %INSTANCES;

my %message_handler = (
    ws_redis_master => sub {
        my ($redis, $msg, $channel) = @_;
        Binary::WebSocketAPI::v3::Wrapper::Streamer::send_notification($redis->{shared_info}, $msg, $channel)
            if $channel eq 'NOTIFY::broadcast::channel';
    });

sub create {
    my $name = shift;

    my $server = $servers->{$name} // die 'unknown Redis instance ' . $name;

    my $cf        = LoadFile($server->{current_config})->{$server->{user}};
    my $redis_url = Mojo::URL->new("redis://$cf->{host}:$cf->{port}");

    $redis_url->userinfo('dummy:' . $cf->{password}) if $cf->{password};

    my $redis = Mojo::Redis2->new(url => $redis_url);
    # NOTICE Mojo::Redis2 will 'encode_utf8' and 'decode_utf8' automatically
    # when it send and receive messages. And before and after that we do
    # encode and decode again. That means we do 'encode' & 'decode' twice.
    # In most cases it is ok. I'm afraid that will cause new problem if we
    # fix it. And we will replace Mojo::Redis2 in the future, so we don't
    # fix it now. But in shared_redis and transaction redis, we send it by
    # RedisDB, that will generate an error 'wide character' when we decode
    # message twice. So we disable it now
    $redis->encoding(undef) if $name =~ /^(?:shared_redis|redis_transaction)$/;
    $redis->on(
        connection => sub {
            stats_inc('bom_websocket_api.v_3.redis_instances.' . $name . '.connections');
        },
        error => sub {
            my ($self, $err) = @_;
            warn("Redis $name error: $err");

            stats_inc('bom_websocket_api.v_3.redis_instances.' . $name . '.errors');
        });

    return $redis;
}

sub check_connections {
    my $server;
    for my $server_name (sort keys %$servers) {
        try {
            undef $server;
            $server_name = $server_name;
            $server      = __PACKAGE__->$server_name();
            $server->ping() if $server;
        }
        catch {
            if ($server) {
                # Clear current_config from server if server ping fails
                delete $servers->{$server_name}->{current_config};
                die "Redis server $server_name does not work! Host: "
                    . (eval { $server->url->host } // "(failed - $@)")
                    . ", port: "
                    . (eval { $server->url->port } // "(failed - $@)")
                    . ", reason: "
                    . $_;
            } else {
                die "$server_name is not available: " . $_;
            }
        }
    }
    return 1;
}

# Autopopulate remaining methods
for my $name (sort keys %$servers) {
    my $code = sub {
        my $server = $servers->{$name};
        my $config_file = $ENV{$server->{override}} // $server->{config};
        # Reload server if config file location has changed
        if (($server->{current_config} // '') ne $config_file) {
            $server->{current_config} = $config_file;
            my $redis = create($name);
            $redis->on(message => $message_handler{$name}) if exists $message_handler{$name};
            $redis->{shared_info} ||= {};
            $INSTANCES{$name} = $redis;
        }
        return $INSTANCES{$name};
    };
    {
        no strict 'refs';
        *$name = $code
    }
}

1;
