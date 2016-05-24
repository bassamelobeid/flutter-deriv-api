package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Mojo::IOLoop;

use Try::Tiny;
use Data::UUID;

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

    $app->plugin(
        'BOM::WebSocketAPI::Plugins::WebSocketProxy' => {
            forward => [
                ['authorize'],
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

                ['app_register', {require_auth => 'admin'}],
                ['app_list',     {require_auth => 'admin'}],
                ['app_get',      {require_auth => 'admin'}],
                ['app_delete',   {require_auth => 'admin'}],
                ['oauth_apps',   {require_auth => 'admin'}],

                ['profit_table',       {require_auth => 'read'}],
                ['get_account_status', {require_auth => 'read'}],
                [
                    'change_password',
                    {
                        require_auth => 'admin',
                        stash_params => [qw/ token_type client_ip /]}
                ],
                ['get_settings', {require_auth => 'read'}],
                [
                    'set_settings',
                    {
                        require_auth => 'admin',
                        stash_params => [qw/ server_name client_ip user_agent /]}
                ],
                ['get_self_exclusion', {require_auth => 'read'}],
                [
                    'set_self_exclusion',
                    {
                        require_auth => 'admin',
                        response     => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion_response_handler
                    }
                ],
                [
                    'cashier_password',
                    {
                        require_auth => 'payments',
                        stash_params => [qw/ client_ip /]}
                ],
            ],
            base_path                => '/websockets/v3',
            before_forward           => [\&before_forward],
            before_call              => [\&start_timing],
            before_get_rpc_response  => [\&log_call_timing],
            after_got_rpc_response   => [\&log_call_timing_connection],
            before_send_api_response => [\&add_debug_time, \&start_timing],
            after_sent_api_response  => [\&log_call_timing_sent],
        });

    return;
}

sub start_timing {
    my ($c, $params) = @_;
    $params->{tv} = [Time::HiRes::gettimeofday];
    return;
}

sub log_call_timing {
    my ($c, $params) = @_;
    DataDog::DogStatsd::Helper::stats_timing(
        'bom_websocket_api.v_3.rpc.call.timing',
        1000 * Time::HiRes::tv_interval($params->{tv}),
        {tags => ["rpc:$params->{method}"]});
    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.rpc.call.count', {tags => ["rpc:$params->{method}"]});
    return;
}

sub log_call_timing_connection {
    my ($c, $params, $rpc_response) = @_;
    if (ref($rpc_response->result) eq "HASH"
        && (my $rpc_time = delete $rpc_response->result->{rpc_time}))
    {
        DataDog::DogStatsd::Helper::stats_timing(
            'bom_websocket_api.v_3.rpc.call.timing.connection',
            1000 * Time::HiRes::tv_interval($params->{tv}) - $rpc_time,
            {tags => ["rpc:$params->{method}"]});
    }
    return;
}

sub add_debug_time {
    my ($c, $params, $api_response) = @_;
    if ($c->stash('debug')) {
        $api_response->{debug} = {
            time   => 1000 * Time::HiRes::tv_interval($params->{tv}),
            method => $params->{method},
        };
    }
    return;
}

sub log_call_timing_sent {
    my ($c, $params) = @_;
    DataDog::DogStatsd::Helper::stats_timing(
        'bom_websocket_api.v_3.rpc.call.timing.sent',
        1000 * Time::HiRes::tv_interval($params->{tv}),
        {tags => ["rpc:$params->{method}"]});
    return;
}

sub before_forward {
    my ($c, $p1, $req) = @_;

    if (not $c->stash('connection_id')) {
        $c->stash('connection_id' => Data::UUID->new()->create_str());
    }

    $req->{handle_t0} = [Time::HiRes::gettimeofday];

    my $tag = 'origin:';
    if (my $origin = $c->req->headers->header("Origin")) {
        if ($origin =~ /https?:\/\/([a-zA-Z0-9\.]+)$/) {
            $tag = "origin:$1";
        }
    }

    # For authorized calls that are heavier we will limit based on loginid
    # For unauthorized calls that are less heavy we will use connection id.
    # None are much helpful in a well prepared DDoS.
    my $consumer = $c->stash('loginid') || $c->stash('connection_id');

    if (_reached_limit_check($consumer, $req->{name}, $c->stash('loginid') && !$c->stash('is_virtual'))) {
        return $c->new_error($req->{name}, 'RateLimit', $c->l('You have reached the rate limit for [_1].', $req->{name}));
    }

    my $input_validation_result = $req->{in_validator}->validate($p1);
    if (not $input_validation_result) {
        my ($details, @general);
        foreach my $err ($input_validation_result->errors) {
            if ($err->property =~ /\$\.(.+)$/) {
                $details->{$1} = $err->message;
            } else {
                push @general, $err->message;
            }
        }
        my $message = $c->l('Input validation failed: ') . join(', ', (keys %$details, @general));
        return $c->new_error($req->{name}, 'InputValidationFailed', $message, $details);
    }

    _set_defaults($req, $p1);

    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.' . $req->{name}, {tags => [$tag]});
    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.all', {tags => [$tag, "category:$req->{name}"]});

    my $loginid = $c->stash('loginid');
    if ($req->{require_auth} and not $loginid) {
        return $c->new_error($req->{name}, 'AuthorizationRequired', $c->l('Please log in.'));
    }

    if ($req->{require_auth} and not(grep { $_ eq $req->{require_auth} } @{$c->stash('scopes') || []})) {
        return $c->new_error($req->{name}, 'PermissionDenied', $c->l('Permission denied, requiring [_1]', $req->{require_auth}));
    }

    if ($loginid) {
        my $account_type = $c->stash('is_virtual') ? 'virtual' : 'real';
        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.authenticated_call.all',
            {tags => [$tag, $req->{name}, "account_type:$account_type"]});
    }

    return;
}

1;
