package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';

sub startup {
    my $app = shift;

    $app->moniker('bom-websockets-api');
    $app->plugin('BOM::Utility::Mojolicious::Plugin::System', port=>5004);

    my $log = $app->log;

    $log->info("WebsocketsAPI: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->debug("Server config    is " . $app->dumper($app->config));

    my $r = $app->routes;

    for ($r->under('/websockets')) {
        $_->to('websocket#ok');
        $_->websocket('/contracts')->to('#contracts');
    }

    return;
}

1;

