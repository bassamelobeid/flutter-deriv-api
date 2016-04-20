package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Mojo::IOLoop;
use Try::Tiny;

use BOM::Platform::Context ();
use BOM::Platform::Context::Request;
# pre-load controlleres to have more shared code among workers (COW)
use BOM::WebSocketAPI::Websocket_v3();

sub apply_usergroup {
    my ($cf, $log) = @_;

    if ($> == 0) {    # we are root
        my $group = $cf->{group};
        if ($group) {
            $group = (getgrnam $group)[2] unless $group =~ /^\d+$/;
            $(     = $group;                                          ## no critic
            $)     = "$group $group";                                 ## no critic
            $log->("Switched group: RGID=$( EGID=$)");
        }

        my $user = $cf->{user} // 'nobody';
        if ($user) {
            $user = (getpwnam $user)[2] unless $user =~ /^\d+$/;
            $<    = $user;                                            ## no critic
            $>    = $user;                                            ## no critic
            $log->("Switched user: RUID=$< EUID=$>");
        }
    }
    return;
}

sub startup {
    my $app = shift;

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my ($reactor, $err) = @_;
            $app->log->error("EventLoop error: $err");
        });

    $app->moniker('websocket');
    $app->plugin('Config' => {file => $ENV{WEBSOCKET_CONFIG} || '/etc/rmg/websocket.conf'});

    my $log = $app->log;

    my $signature = "Binary.com Websockets API";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);

    apply_usergroup $app->config->{hypnotoad}, sub {
        $log->info(@_);
    };

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

            if ($request->param('debug')) {
                $c->stash(debug => 1);
            }

        });

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

    for ($r->under('/websockets/v3')) {
        $_->to('Websocket_v3#ok');
        $_->websocket('/')->to('#entry_point');
    }

    return;
}

1;
