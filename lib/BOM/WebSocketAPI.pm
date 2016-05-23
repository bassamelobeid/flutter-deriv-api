package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Mojo::IOLoop;
use Try::Tiny;

# pre-load controlleres to have more shared code among workers (COW)
use BOM::WebSocketAPI::Websocket_v3();
use BOM::WebSocketAPI::CallingEngine();

use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use BOM::WebSocketAPI::v3::Wrapper::Transaction;
use BOM::WebSocketAPI::v3::Wrapper::Authorize;
use BOM::WebSocketAPI::v3::Wrapper::System;
use BOM::WebSocketAPI::v3::Wrapper::Accounts;
use BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;
use BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;
use BOM::WebSocketAPI::v3::Wrapper::Cashier;
use BOM::WebSocketAPI::v3::Wrapper::NewAccount;
use BOM::WebSocketAPI::v3::Wrapper::Pricer;

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

            if ($c->req->param('debug')) {
                $c->stash(debug => 1);
            }

            if ($c->req->param('app_id')) {
                my $app_id = $c->req->param('app_id');

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
                        source   => $app_id,
                        app_name => $app->{name},
                    );
                }

                if ($error) {
                    $c->send({json => $c->new_error('error', 'InvalidAppID', $c->l('Your app_id is invalid.'))});
                    $c->finish();
                }
            }

            $c->stash(
                server_name  => $c->server_name,
                client_ip    => $c->client_ip,
                country_code => $c->country_code,
                user_agent   => $c->req->headers->header('User-Agent'),
            );
        });

    $app->plugin('ClientIP');
    $app->plugin('BOM::WebSocketAPI::Plugins::Helpers');

    $app->plugin('BOM::WebSocketAPI::Plugins::WebSocketProxy' => {
        forward => [
            ['authorize']
            [
                'logout',
                {
                    stash_params => [qw/ token token_type email client_ip country_code user_agent /],
                    success      => \&BOM::WebSocketAPI::v3::Wrapper::Authorize::logout_success,
                },
            ],
            ['trading_times'],
            [
                'asset_index',
                {
                    before_forward => \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::asset_index_cached,
                    success        => \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::cache_asset_index,
                }
            ],
            ['active_symbols', {stash_params => [qw/ token /]}],

            ['profit_table', {require_auth => 'read'}],
            ['get_account_status', {require_auth => 'read'}],
            ['change_password', {require_auth => 'admin', stash_params => [qw/ token_type client_ip /]}],
            ['get_settings', {require_auth => 'read'}],
            ['set_settings', {require_auth => 'admin', stash_params => [qw/ server_name client_ip user_agent /]}],
            ['get_self_exclusion', {require_auth => 'read'}],
            ['set_self_exclusion', {require_auth => 'admin', response     => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion_response_handler}],
            ['cashier_password', {require_auth => 'payments', stash_params => [qw/ client_ip /]}],
        ],
        base_path => '/websockets/v3',
    });

    # my $r = $app->routes;

    # for ($r->under('/websockets/v3')) {
    #     $_->to('Websocket_v3#ok');
    #     $_->websocket('/')->to('#entry_point');
    # }

    # my $r = $app->routes;

    # for ($r->under('/websockets/v3')) {
    #     $_->to('Dispatcher#ok', namespace => 'BOM::WebSocketAPI');
    #     $_->websocket('/')->to('Dispatcher#forward', namespace => 'BOM::WebSocketAPI');
    # }

    return;
}

1;
