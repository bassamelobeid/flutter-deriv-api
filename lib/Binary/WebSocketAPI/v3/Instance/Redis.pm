package Binary::WebSocketAPI::v3::Instance::Redis;

use strict;
use warnings;

no indirect;

use YAML::XS qw| LoadFile |;
use Exporter qw| import   |;
use DataDog::DogStatsd::Helper qw| stats_inc stats_dec |;
use Try::Tiny;
use Mojo::Redis2;
use Scalar::Util qw(looks_like_number);

my $config = {
    shared_redis    => LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/chronicle.yml')->{read},
    redis_pricer    => LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write},
    ws_redis_slave  => LoadFile($ENV{BOM_TEST_WS_REDIS}         // '/etc/rmg/ws-redis.yml')->{read},
    ws_redis_master => LoadFile($ENV{BOM_TEST_WS_REDIS}         // '/etc/rmg/ws-redis.yml')->{write},
};

my $instances = {
    redis_pricer    => undef,
    ws_redis_slave  => undef,
    ws_redis_master => undef,
    shared_redis    => undef,
};

our @EXPORT_OK = (keys %$config, 'check_connections');

sub instances {
    return $instances;
}

sub create {
    my $name = shift;

    my $cf        = $config->{$name};
    my $redis_url = Mojo::URL->new("redis://$cf->{host}:$cf->{port}");

    $redis_url->userinfo('dummy:' . $cf->{password}) if $cf->{password};

    my $server = Mojo::Redis2->new(url => $redis_url);
    $server->on(
        connection => sub { stats_inc('bom_websocket_api.v_3.redis_instances.' . $name . '.connections') },
        error      => sub {
            my ($self, $err) = @_;
            warn("Redis $name error: $err");
            stats_inc('bom_websocket_api.v_3.redis_instances.' . $name . '.errors');
        });

    return $server;
}

sub check_connections {
    my ($server, $server_name);
    try {
        for my $sn (keys %$config) {
            undef $server;
            $server_name = $sn;
            $server      = __PACKAGE__->$server_name();
            $server->ping() if $server;
        }
    }
    catch {
        if ($server) {
            die "Redis server $server_name does not work! Host: " . $server->url->host . ", port: " . $server->url->port . "\nREASON: " . $_;
        } else {
            die "$server_name is not available:" . $_;
        }
    };
    return 1;
}

sub redis_pricer {
    my $name = 'redis_pricer';
    return $instances->{$name} if defined $instances->{$name};

    $instances->{$name} = create($name);
    $instances->{$name}->on(
        message => sub {
            my ($self, $msg, $channel) = @_;
            if ($self->{shared_info}{$channel}) {
                foreach my $c_key (keys %{$self->{shared_info}{$channel}}) {
                    unless ($self->{shared_info}{$channel}{$c_key} && ref $self->{shared_info}{$channel}{$c_key}) {
                        delete $self->{shared_info}{$channel}{$c_key};
                        next;
                    }
                    Binary::WebSocketAPI::v3::Wrapper::Pricer::process_pricing_events($self->{shared_info}{$channel}{$c_key}, $msg, $channel);
                }
            }
        });
    $instances->{$name}{shared_info} = {};
    return $instances->{$name};
}

sub ws_redis_master {
    my $name = 'ws_redis_master';
    return $instances->{$name} if defined $instances->{$name};

    $instances->{$name} = create($name);
    $instances->{$name}->on(
        message => sub {
            my ($self, $msg, $channel) = @_;
            return unless $channel eq 'NOTIFY::broadcast::channel';
            Binary::WebSocketAPI::v3::Wrapper::Streamer::send_notification($self->{shared_info}, $msg, $channel);
        });
    $instances->{$name}{shared_info} = {};
    return $instances->{$name};
}

sub ws_redis_slave {
    my $name = 'ws_redis_slave';
    return $instances->{$name} if defined $instances->{$name};

    return create($name);
}

sub shared_redis {
    my $name = 'shared_redis';
    return $instances->{$name} if defined $instances->{$name};

    $instances->{$name} = create($name);
    $instances->{$name}->on(
        message => sub {
            my ($self, $msg, $channel) = @_;
            return unless $channel =~ /^FEED::/ || $channel =~ /^TXNUPDATE::transaction_/;

            if ($self->{shared_info}{$channel}) {
                foreach my $c_key (keys %{$self->{shared_info}{$channel}}) {
                    next unless looks_like_number($c_key);
                    unless ($self->{shared_info}{$channel}{$c_key}
                        && ref $self->{shared_info}{$channel}{$c_key}
                        && $self->{shared_info}{$channel}{$c_key}{c})
                    {
                        delete $self->{shared_info}{$channel}{$c_key};
                        next;
                    }
                    Binary::WebSocketAPI::v3::Wrapper::Streamer::process_realtime_events($self->{shared_info}{$channel}{$c_key}, $msg, $channel)
                        if $channel =~ /^FEED::/;
                    Binary::WebSocketAPI::v3::Wrapper::Streamer::process_transaction_updates($self->{shared_info}{$channel}{$c_key}, $msg, $channel)
                        if $channel =~ /^TXNUPDATE::transaction_/;
                }
            }
        });
    $instances->{$name}{shared_info} = {};
    return $instances->{$name};
}

1;
