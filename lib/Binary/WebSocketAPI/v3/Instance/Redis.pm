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
use List::Util   qw(any);
use Log::Any     qw($log);

=head2 redis_feed_master

redis for feed data

=head2 redis_transanction

redis for transaction update (E.g. account balance)

=head2 redis_pricer

redis that contain pricing request data

=head2 redis_pricer_subscription

redis solely for handling contract pricing pub/sub

=head2 ws_redis_master

redis for websocket operations

=head2 redis_rpc

redis for websocket-rpc communication

=head2 redis_p2p

redis for p2p operations

=head2 redis_exchange_rates

redis for exchange rates pub/sub

=cut

# Add entries here if a new Redis instance is available, this will then be accessible
# via a function of the same name.
my $servers = {
    redis_feed_master => {
        config => '/etc/rmg/redis-feed.yml',
        user   => 'master-read',
    },
    redis_transaction => {
        config => '/etc/rmg/redis-transaction.yml',
        user   => 'read',
    },
    redis_pricer => {
        config => '/etc/rmg/redis-pricer.yml',
        user   => 'write',
    },
    redis_pricer_subscription => {
        config => '/etc/rmg/redis-pricer-subscription.yml',
        user   => 'write',
    },
    ws_redis_master => {
        config => '/etc/rmg/ws-redis.yml',
        user   => 'write',
    },
    redis_rpc => {
        config => '/etc/rmg/redis-rpc.yml',
        user   => 'write',
    },
    redis_p2p => {
        config => '/etc/rmg/redis-p2p.yml',
        user   => 'read',
    },
    redis_exchange_rates => {
        config => '/etc/rmg/redis-exchangerates.yml',
        user   => 'read',
    },
    redis_mt5_user => {
        config => '/etc/rmg/redis-mt5user.yml',
        user   => 'read',
    },
};
# We export (on demand) all Redis names and a helper function.
our @EXPORT_OK = ('check_connections', sort keys %$servers);

# Used to cache the singletons.
our %INSTANCES;

my %message_handler = (
    ws_redis_master => sub {
        my ($redis, $msg, $channel) = @_;
        Binary::WebSocketAPI::v3::Wrapper::Streamer::send_broadcast_notification($redis->{shared_info}, $msg, $channel)
            if $channel eq 'NOTIFY::broadcast::channel';
    });

sub create {
    my $name   = shift;
    my $server = $servers->{$name} // die 'unknown Redis instance ' . $name;
    if (!$server->{current_config}) {
        $server->{current_config} = $server->{config};
    }
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
    $redis->encoding(undef) if $name =~ /^redis_(?:transaction|p2p|rpc|pricer_subscription)$/;

    $redis->on(
        error => sub {
            my ($self, $err) = @_;
            $log->errorf('Redis %s(%s) error: %s', $name, $redis_url, $err);
            # When redis connection is lost wait until redis server become
            # available then terminate the service so that hypnotoad will
            # restart it.
            return if ($err ne 'Connection refused');
            my $ping_redis = sub {
                my $retry_delay = 1;    #retry ping after every sec of failure
                my $loop_timer_id;
                $loop_timer_id = Mojo::IOLoop->recurring(
                    $retry_delay => sub {
                        try {
                            # This die to cover bug in Mojo::Redis2, if we're doing a request to Redis
                            # But we have connection problem, our callback will not be dequeued from waiting queue.
                            # Because of that our ping may not throw exception here.
                            die "Connection to Redis is not recovered" unless $self->ping;
                            $log->warnf('Redis connection %s(%s) is recovered', $name, $redis_url);
                            Mojo::IOLoop->remove($loop_timer_id);    # remove the associated timer (closure for MOJO Loop)
                            exit;
                        } catch ($e) {
                            $log->errorf('Unable to connect to redis %s(%s):%s', $name, $redis_url, $e);
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
            } catch ($e) {
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
        sleep $seconds                                                                     if any { !$run_checklist{$_} } keys %$servers;
        $slept_seconds += $seconds;
        $seconds       *= 2;
    }

    return 1;
}

# Autopopulate remaining methods
for my $name (sort keys %$servers) {
    my $code = sub {
        my $server      = $servers->{$name};
        my $config_file = $server->{config};
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
