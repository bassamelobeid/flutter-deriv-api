package Binary::WebSocketAPI::v3::Instance::Redis;

use strict;
use warnings;
use Data::Dumper;
use YAML::XS qw| LoadFile |;
use Exporter qw( import );

use parent qw( Mojo::Redis2 );

### TODO: Doing something with it
my $pricer_cf = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml');
#my $ws_cf  = YAML::XS::LoadFile('/etc/rmg/ws-redis.yml');

my $config = {
    pricer_write => $pricer_cf->{write},
    pricer_read  => $pricer_cf->{read},
#    ws_write => $ws_cf->{write},
#    ws_read  => $ws_cf->{read},
};

$config->{pricer_write}{afterwork} = sub {
    shift->on(
        message => sub {
            my ($self, $msg, $channel) = @_;
            Binary::WebSocketAPI::v3::Wrapper::Streamer::send_notification($self->{shared_info}, $msg, $channel);
        });
};

=pod

$config->{ws_write}{afterwork} = sub {
    warn "WRITE WS AFTERWORK";
    shift->on(
        message => sub {
            my ($self, $msg, $channel) = @_;
            warn "GOT MESSAGE: " . Dumper $msg;
#           my $shared_info = $app->redis_connections($channel);
            Binary::WebSocketAPI::v3::Wrapper::Streamer::send_notification($self->{shared_info}, $msg, $channel);
    });
};

=cut

my $instances = {
    pricer_write => undef,
    pricer_read  => undef,
};

sub new {
    my ($class, $name) = @_;

    my $cf        = $config->{$name};
    my $redis_url = Mojo::URL->new("redis://$cf->{host}:$cf->{port}");

    $redis_url->userinfo('dummy:' . $cf->{password}) if $cf->{password};

    my $self = $class->SUPER::new(url => $redis_url);
    $self->on(
        error => sub {
            my ($self, $err) = @_;
            warn("Redis $name error: $err");
        });
    ### Temporary trick
    if ($name eq 'pricer_write') {
        $self->on(
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
    }
    $self->{shared_info} = {};
#    $cf->{afterwork}->($self) if $cf->{afterwork};
    return $self;
}

my $work_pid = 0;

sub AUTOLOAD {
    my $self = shift;

    (my $name = our $AUTOLOAD) =~ s/.*:://;    ### Not sure about it. Regexp every call...

    return unless $config->{$name};

    my $pid = $$;
    if ($work_pid != $pid) {
        $instances->{$name} = undef;
        $work_pid = $pid;
    }
    $instances->{$name} //= __PACKAGE__->new($name);

    return $instances->{$name};
}

our @EXPORT_OK = keys %$config;

1;
