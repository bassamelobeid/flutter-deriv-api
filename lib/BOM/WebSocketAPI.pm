package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';

use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::Request;

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

    # add few helpers
    $app->helper(
        app_config => sub {
            state $app_config = BOM::Platform::Runtime->instance->app_config;
            return $app_config;
        });

    $app->helper(
        new_error => sub {
            my $c = shift;
            my ($msg_type, $code, $message) = scalar(@_) > 2 ? @_ : ('error', @_);
            return {
                msg_type => $msg_type,
                error    => {
                    code    => $code,
                    message => $message
                }};
        });

    $app->hook(
        before_dispatch => sub {
            my $c = shift;
            try {
                my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => $c->req});
                if ($request) {
                    BOM::Platform::Context::request($request);
                }
            }
            catch {
                $c->app->log->error($_);
            };

            my $request = BOM::Platform::Context::request();
            $c->stash(request => $request);
            my $lang = lc $c->stash('request')->language;
            $c->stash(language => uc $lang);
            $c->res->headers->header('Content-Language' => $lang);
        });

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
