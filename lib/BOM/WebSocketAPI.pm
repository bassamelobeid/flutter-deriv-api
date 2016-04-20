package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Mojo::IOLoop;
use Try::Tiny;
use Data::Validate::IP;
use Sys::Hostname;

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

            if (my $lang = $c->param('l')) {
                $c->stash(language => uc $lang);
                $c->res->headers->header('Content-Language' => lc $lang);
            }

            if ($c->req->params->{'debug'}) {
                $c->stash(debug => 1);
            }
        });

    $app->helper(
        client_ip => sub {
            my $self = shift;

            return $self->stash->{client_ip} if $self->stash->{client_ip};
            if (my $ip = $self->req->headers->header('x-forwarded-for')) {
                ($self->stash->{client_ip}) =
                    grep { Data::Validate::IP::is_ipv4($_) }
                    split(/,\s*/, $ip);
            }
            return $self->stash->{client_ip};
        });

    $app->helper(
        server_name => sub {
            my $self = shift;

            return [split(/\./, Sys::Hostname::hostname)]->[0];
        });

    $app->helper(
        country_code => sub {
            my $self = shift;

            return $self->stash->{country_code} if $self->stash->{country_code};
            my $client_country = lc($self->req->headers->header('CF-IPCOUNTRY') || 'aq');
            $client_country = 'aq' if ($client_country eq 'xx');
            my $ip = $self->client_ip;
            if (($ip =~ /^99\.99\.99\./) or ($ip =~ /^192\.168\./) or ($ip eq '127.0.0.1')) {
                $client_country = 'aq';
            }
            return $self->stash->{country_code} = $client_country;
        });

    $app->helper(
        l => sub {
            my $self = shift;

            state $lh = BOM::Platform::Context::I18N::handle_for($self->stash('language'))
                || die("could not build locale for language " . $self->stash('language'));

            return $lh->maketext(@_);
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
