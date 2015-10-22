package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';

sub startup {
    my $app = shift;

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my ($reactor, $err) = @_;
            $app->log->error("EventLoop error: $err");
        });

    $app->moniker('websocket');
    $app->plugin('Config');

    my $log = $app->log;

    my $signature = "Binary.com Websockets API";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);
    $log->debug("Server config    is " . $app->dumper($app->config));

    my $r = $app->routes;

    for ($r->under('/websockets/v1')) {
        $_->to('Websocket_v1#ok');
        $_->websocket('/')->to('#entry_point');
    }

    for ($r->under('/websockets/v2')) {
        $_->to('Websocket_v2#ok');
        $_->websocket('/')->to('#entry_point');
    }

    for ($r->under('/websockets/v3')) {
        $_->to('Websocket_v3#ok');
        $_->websocket('/')->to('#entry_point');
    }

    # Alias, to be deprecated.
    for ($r->under('/websockets/contracts')) {
        $_->to('Websocket_v1#ok');
        $_->websocket('/')->to('#entry_point');
    }

    return;
}

1;
