package Binary::WebSocketAPI::v3::Instance::Redis;
use strict;
use warnings;
use Data::Dumper;
use YAML::XS qw| LoadFile |;
use Exporter qw( import );

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

    my $server = Mojo::Redis2->new(url => $redis_url);
    $server->on(
        error => sub {
            my ($self, $err) = @_;
            warn("Redis $name error: $err");
        });
    return $server;
}

sub pricer_write {
    my $name = 'pricer_write';
    return $instances->{$name} if defined $instances->{$name};

    $instances->{$name} = create($name);
    $instances->{$name}->on(
        message => sub {
            my ($self, $msg, $channel) = @_;
            if ($self->{shared_info}{$channel}) {
                foreach my $uuid (keys %{$self->{shared_info}{$channel}}) {
                    ### Is memory leak here?
                    my $c = $self->{shared_info}{$channel}{$uuid};
                    Binary::WebSocketAPI::v3::Wrapper::Pricer::process_pricing_events($c, $msg, $channel) if ref $c;
                }
            }
        });
    $instances->{$name}{shared_info} = {};
    return $instances->{$name};
}

our @EXPORT_OK = keys %$config;

1;
