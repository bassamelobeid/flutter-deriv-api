package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Mojo::IOLoop;
use Try::Tiny;
use Format::Util::Strings qw( defang_lite );
use Digest::MD5 qw(md5_hex);

# pre-load controlleres to have more shared code among workers (COW)
use BOM::WebSocketAPI::Websocket_v3();
use BOM::WebSocketAPI::CallingEngine();

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

            my $lang = defang_lite($c->param('l'));
            if ($lang =~ /^\D{2}(_\D{2})?$/) {
                $c->stash(language => uc $lang);
                $c->res->headers->header('Content-Language' => lc $lang);
            } else {
                # default to English if not valid language
                $c->stash(language => 'EN');
                $c->res->headers->header('Content-Language' => 'en');
            }

            if ($c->req->param('debug')) {
                $c->stash(debug => 1);
            }

            my $app_id;
            if ($c->req->param('app_id')) {
                $app_id = defang_lite($c->req->param('app_id'));

                my $error;
                APP_ID:
                {
                    if ($app_id !~ /^\d+$/) {
                        $error = 1;
                        last;
                    }

                    my $oauth = BOM::Database::Model::OAuth->new;
                    my $app   = $oauth->verify_app($app_id);

                    if (not $app) {
                        $error = 1;
                        last;
                    }

                    $c->stash(
                        source                => $app_id,
                        app_markup_percentage => $app->{app_markup_percentage} // 0
                    );
                }

                if ($error) {
                    $c->send({json => $c->new_error('error', 'InvalidAppID', $c->l('Your app_id is invalid.'))});
                    $c->finish();
                }
            }
            my $client_ip = $c->client_ip;

            if ($c->tx and $c->tx->req and $c->tx->req->headers->header('REMOTE_ADDR')) {
                $client_ip = $c->tx->req->headers->header('REMOTE_ADDR');
            }

            my $user_agent = $c->req->headers->header('User-Agent');
            $c->stash(
                server_name    => $c->server_name,
                client_ip      => $client_ip,
                country_code   => $c->country_code,
                user_agent     => $user_agent,
                ua_fingerprint => md5_hex(($app_id // 0) . ($client_ip // '') . ($user_agent // '')),
            );
        });

    $app->plugin('ClientIP');
    $app->plugin('BOM::WebSocketAPI::Plugins::Helpers');

    my $r = $app->routes;

    for ($r->under('/websockets/v3')) {
        $_->to('Websocket_v3#ok');
        $_->websocket('/')->to('#entry_point');
    }

    return;
}

1;
