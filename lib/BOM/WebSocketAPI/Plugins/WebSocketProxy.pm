package BOM::WebSocketAPI::Plugins::WebSocketProxy;

use Mojo::Base 'Mojolicious::Plugin';
use BOM::WebSocketAPI::Dispatcher::Config;
use BOM::WebSocketAPI::Dispatcher;

sub register {
    my ($self, $app, $config) = @_;

    my $r = $app->routes;
    for ($r->under('/websockets/v3')) {
        $_->to('Dispatcher#ok', namespace => 'BOM::WebSocketAPI');
        $_->websocket('/')->to('Dispatcher#open_connection', namespace => 'BOM::WebSocketAPI');
    }

    my $actions = delete $config->{actions};

    my $dispatcher_config = BOM::WebSocketAPI::Dispatcher::Config->new;
    $dispatcher_config->init($config);

    if (ref $actions eq 'ARRAY') {
        for (my $i = 0; $i < @$actions; $i++) {
            $dispatcher_config->add_action($actions->[$i], $i);
        }
    } else {
        Carp::confess 'No actions found!';
    }

    $app->helper(
        call_rpc => sub {
            my ($c, $req_storage) = @_;
            return $c->forward($req_storage);
        });

    return;
}

1;
