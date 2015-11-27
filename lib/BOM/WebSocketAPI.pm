package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Try::Tiny;

use BOM::Platform::Runtime;
use BOM::Platform::Context ();
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

    $app->hook(
        before_dispatch => sub {
            my $c = shift;
            $c->cookie(
                language => '',
                {expires => 1});

            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => $c->req});
            $request = BOM::Platform::Context::request($request);
            $c->stash(request => $request);
            if (my $lang = lc $request->language) {
                $c->stash(language => uc $lang);
                $c->res->headers->header('Content-Language' => $lang);
            }
        });

    # pre-load controlleres to have more shared code among workers (COW)
    
    # add few helpers
    
    for (qw/Websocket_v1 Websocket_v2 Websocket_v3/) {
        my $module = __PACKAGE__ . "::$_";
        eval "use $module;";
        if ($@) {
            my $msg = "Cannnot pre-load $module: $@, exiting";
            $log->error($msg);
            die($@)
        }
    }
    
    # pre-load config to be shared among workers
    my $app_config = BOM::Platform::Runtime->instance->app_config;
    $app->helper(
        app_config => sub { return $app_config }
        );

    $app->helper(
        l => sub {
            my $self = shift;
            return BOM::Platform::Context::localize(@_);
        });

    $app->helper(
        new_error => sub {
            my $c = shift;
            my ($msg_type, $code, $message, $details) = @_;

            my $error = {
                code    => $code,
                message => $message
            };
            $error->{details} = $details if (keys %$details);

            return {
                msg_type => $msg_type,
                error    => $error,
            };
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
