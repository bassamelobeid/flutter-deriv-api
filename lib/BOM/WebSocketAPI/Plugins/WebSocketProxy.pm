package BOM::WebSocketAPI::Plugins::WebSocketProxy;

use Mojo::Base 'Mojolicious::Plugin';
use BOM::WebSocketAPI::Dispatcher;

sub register {
    my ($self, $app, $config) = @_;

    my $r = $app->routes;
    for ($r->under('/websockets/v3')) {
        $_->to('Dispatcher#ok', namespace => 'BOM::WebSocketAPI');
        $_->websocket('/')->to('Dispatcher#connect', namespace => 'BOM::WebSocketAPI');
    }

    my $routes = delete $config->{forward};

    BOM::WebSocketAPI::Dispatcher::init($self, $config);

    if (ref $routes eq 'HASH') {
        for (my $i; i < @routes; $i++) {
            BOM::WebSocketAPI::Dispatcher::add_route($self, $action, $i);
        }
    } else {
        Carp::confess 'No actions found!';
    }

    return;
}

1;
