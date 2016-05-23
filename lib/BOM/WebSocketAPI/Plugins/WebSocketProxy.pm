package BOM::WebSocketAPI::Plugins::WebSocketProxy;

use Mojo::Base 'Mojolicious::Plugin';
use BOM::WebSocketAPI::Dispatcher;

sub register {
    my ($self, $app, $conf) = @_;

    my $r = $app->routes;
    for ($r->under('/websockets/v3')) {
        $_->to('Dispatcher#ok', namespace => 'BOM::WebSocketAPI');
        $_->websocket('/')->to('Dispatcher#connect', namespace => 'BOM::WebSocketAPI');
    }

    if (exists $conf->{forward} && ref $conf->{forward} eq 'HASH') {
        my @actions = @{$conf->{forward}};
        for (my $i; i < @actions; $i++) {
            BOM::WebSocketAPI::Dispatcher::add_route($self, $action, $i);
        }
    } else {
        Carp::confess 'No actions found!';
    }
    return;
}

1;
