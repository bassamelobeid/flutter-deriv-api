package Binary::WebSocketAPI::v3::Instance::Redis;
use strict;
use warnings;
use Data::Dumper;
use YAML::XS qw| LoadFile |;
use Exporter qw( import );
use DataDog::DogStatsd::Helper qw| stats_inc stats_dec |;
use Guard;

use Mojo::Redis2;

my $config = {
    pricer_write => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write},
};

my $instances = {
    pricer_write => undef,
};

sub create {
    my $name = shift;

    my $cf        = $config->{$name};
    my $redis_url = Mojo::URL->new("redis://$cf->{host}:$cf->{port}");

    $redis_url->userinfo('dummy:' . $cf->{password}) if $cf->{password};

    my $guard = guard {
        stats_dec( 'bom_websocket_api.v_3.redis_instances.'.$name );
    };

    my $server = Mojo::Redis2->new(url => $redis_url);
    $server->on(
        connection => sub {
            my $dirty_hack=\$guard;
        },
        error => sub {
            my ($self, $err) = @_;
            warn("Redis $name error: $err");
        });

    stats_inc( 'bom_websocket_api.v_3.redis_instances.'.$name );
    return $server;
}

sub check_connections {
    local $@;

    foreach my $server_name ( keys %$config ) {
        my $server = eval{__PACKAGE__->$server_name()};
        if ( $@ ) {
            die "$server_name is not available:" . $@;
        }
        eval{$server->ping();1;} or do {
            die "Redis server $server_name does not work! Host: ".$server->url->host. ", port: ".$server->url->port . "\nREASON: " .$@;
        }
    }
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
                    delete $self->{shared_info}{$channel}{$c_key}
                        unless $self->{shared_info}{$channel}{$c_key};
                    my $c = $self->{shared_info}{$channel}{$c_key};
                    Binary::WebSocketAPI::v3::Wrapper::Pricer::process_pricing_events($c, $msg, $channel) if ref $c;
                }
            }
        });
    $instances->{$name}{shared_info} = {};
    return $instances->{$name};
}

our @EXPORT_OK = ( keys %$config, 'check_connections');

1;
