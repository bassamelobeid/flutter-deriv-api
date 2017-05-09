package Binary::WebSocketAPI::v3::Instance::Redis;
use strict;
use warnings;
no indirect;
use YAML::XS qw| LoadFile |;
use Exporter qw| import   |;
use DataDog::DogStatsd::Helper qw| stats_inc stats_dec |;
use Try::Tiny;
use Mojo::Redis2;

my $config = {
    pricer_write => LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write},
};

my $instances = {
    pricer_write => undef,
};

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

sub pricer_write {
    my $name = 'pricer_write';
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

our @EXPORT_OK = (keys %$config, 'check_connections');

1;
