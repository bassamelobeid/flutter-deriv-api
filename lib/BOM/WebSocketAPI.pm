package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';

sub startup {
    my $app = shift;

    $app->moniker('websocket');
    $app->plugin('Config');

    my $log = $app->log;

    my $signature = "Binary.com Websockets API";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);
    $log->debug("Server config    is " . $app->dumper($app->config));

    my $r = $app->routes;

    for ($r->under('/websockets/v2')) {
        $_->to('websocket_v1#ok');
        $_->websocket_v1('/')->to('#entry_point');
    }

    # Alias, to be deprecated.
    for ($r->under('/websockets/')) {
        $_->to('websocket_v1#ok');
        $_->websocket_v1('/contracts')->to('#entry_point');
    }

    return;
}

1;
