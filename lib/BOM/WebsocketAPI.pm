package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';

use BOM::System::Config;

sub startup {
    my $app = shift;

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my ($reactor, $err) = @_;
            $app->log->error("EventLoop error: $err");
        });

    $app->moniker('websockets');
    $app->plugin('Config');

    my $log = $app->log;

    my $signature = "Binary.com Websockets API";
    $app->hook(after_dispatch => sub { shift->res->headers->server($signature) });

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);
    $log->debug("Server config    is " . $app->dumper($app->config));

    my $r = $app->routes;

    for ($r->under('/websockets')) {
        $_->to('websockets#ok');
        $_->websocket('/contracts')->to('#contracts');
    }

    return;
}

1;
