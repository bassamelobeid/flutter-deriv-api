package Binary::WebSocketAPI::v3::Instance::Redis;

use strict;
use warnings;

=head1 NAME

Binary::WebSocketAPI::v3::Instance::Redis - manage Redis connections for websocket servers

=head1 DESCRIPTION

Provides a container for dealing with all internal Redis connections.

=cut

no indirect;
use Syntax::Keyword::Try;

use YAML::XS qw(LoadFile);
use Exporter qw(import);
use Mojo::Redis2;
use Scalar::Util qw(looks_like_number);
use List::Util qw(any);

# Add entries here if a new Redis instance is available, this will then be accessible
# via a function of the same name.
my $servers = {
    redis_feed_master => {
        config   => '/etc/rmg/redis-feed.yml',
        user     => 'master-read',
        override => 'BOM_TEST_REDIS_FEED'
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
    redis_pricer_subscription => {
        config   => '/etc/rmg/redis-pricer-subscription.yml',
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
    },
    redis_p2p => {
        config   => '/etc/rmg/redis-p2p.yml',
        user     => 'read',
        override => 'BOM_TEST_REDIS_P2P',
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
    # fix it now. Given that in the redis_transaction, we send it by
    # RedisDB, that will generate an error 'wide character' when we decode
    # message twice. So we disable it now
    $redis->encoding(undef) if $name =~ /^redis_(?:transaction|p2p)$/;
    $redis->on(
        error => sub {
            my ($self, $err) = @_;
            warn("Redis $name error: $err");
            # When redis connection is lost wait until redis server become
            # available then terminate the service so that hypnotoad will
            # restart it.
            return if ($err ne 'Connection refused');
            my $ping_redis;
            $ping_redis = sub {
                Mojo::IOLoop->timer(
                    1 => sub {
                        try {
                            $self->ping;
                            exit;
                        }
                        catch {
                            $ping_redis->();
                        }
                    });
            };
            $ping_redis->();
        });

    return $redis;
}

sub check_connections {
    my $server;

    my %run_checklist = map { $_ => 0 } keys %$servers;
    my $seconds       = 0.5;
    my $slept_seconds = 0;

    # A retry mechanism checking the connection with the redis servers.
    # We will keep checking the connection for a limited time after that
    # the service will die due to timeout.
    # We don't want to start the service if one of the redis is down
    # because it can lead to inconsistent state among workers.
    while (my @pending_servers = grep { !$run_checklist{$_} } keys %$servers) {

        for my $server_name (@pending_servers) {
            try {
                undef $server;
                $server_name = $server_name;
                $server      = __PACKAGE__->$server_name();
                $server->ping() if $server;
                $run_checklist{$server_name} = 1;
            }
            catch {
                my $e = $@;
                if ($server) {
                    # Clear current_config from server if server ping fails
                    delete $servers->{$server_name}->{current_config};
                    warn "Redis server $server_name does not work! Host: "
                        . (eval { $server->url->host } // "(failed - $@)")
                        . ", port: "
                        . (eval { $server->url->port } // "(failed - $@)")
                        . ", reason: "
                        . $e;
                } else {
                    die "$server_name is not available: " . $e;
                }
            }
        }

        die "Timeout $slept_seconds sec while checking the connection with redis servers." if $seconds > 4;
        sleep $seconds if any { !$run_checklist{$_} } keys %$servers;
        $slept_seconds += $seconds;
        $seconds *= 2;
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
