package Binary::WebSocketAPI::Plugins::EVMonitor;

use strict;
use warnings;
no indirect;

use parent qw(Mojolicious::Plugin);

use DataDog::DogStatsd::Helper qw(stats_gauge);
use EV;

sub register {
    my ($self, $app, $conf) = @_;
    my $interval = $conf->{interval};
    Mojo::IOLoop->timer(
        $interval => sub {
            stats_gauge("bom_websocket_api.v_3.EV.pending_count", EV::pending_count);
            stats_gauge("bom_websocket_api.v_3.EV.iteration",     EV::iteration);
        });
    return;
}

1;
