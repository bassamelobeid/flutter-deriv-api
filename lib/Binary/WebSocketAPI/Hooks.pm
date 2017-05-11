package Binary::WebSocketAPI::Hooks;

use strict;
use warnings;

use JSON;
use Try::Tiny;
use Path::Tiny;
use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Fcntl qw/ :flock /;
use Mojo::IOLoop;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use Data::Dumper;

sub start_timing {
    my ($c, $req_storage) = @_;
    if ($req_storage) {
        $req_storage->{tv} = [Time::HiRes::gettimeofday];
    }
    return;
}

sub cleanup_strored_contract_ids {
    my ($c, $req_storage) = @_;
    my $last_contracts = $c->stash('last_contracts') // {};
    my $now = time;
    # see Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_store_last_contract_id
    # keep contract bought in last 60 sec, update stash only if contract list changed
    $c->stash(last_contracts => $last_contracts) if delete @{$last_contracts}{grep { ($now - $last_contracts->{$_}) > 60 } keys %$last_contracts};
    return;
}

sub log_call_timing {
    my ($c, $req_storage) = @_;
    my $tags = ["rpc:$req_storage->{method}", "app_name:" . ($c->stash('app_name') || ''), "app_id:" . ($c->stash('source') || ''),];
    DataDog::DogStatsd::Helper::stats_timing(
        'bom_websocket_api.v_3.rpc.call.timing',
        1000 * Time::HiRes::tv_interval($req_storage->{tv}),
        {tags => $tags});
    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.rpc.call.count', {tags => $tags});
    return;
}

sub log_call_timing_connection {
    my ($c, $req_storage, $rpc_response) = @_;
    if (ref($rpc_response->result) eq "HASH"
        && (my $rpc_time = delete $rpc_response->result->{rpc_time}))
    {
        DataDog::DogStatsd::Helper::stats_timing(
            'bom_websocket_api.v_3.rpc.call.timing.connection',
            1000 * Time::HiRes::tv_interval($req_storage->{tv}) - $rpc_time,
            {tags => ["rpc:$req_storage->{method}"]});
    }
    return;
}

sub add_req_data {
    my ($c, $req_storage, $api_response) = @_;
    if ($req_storage) {
        my $args = $req_storage->{origin_args} || $req_storage->{args};
        $api_response->{echo_req}    = $args;
        $api_response->{req_id}      = $args->{req_id} if $args->{req_id};
        $api_response->{passthrough} = $args->{passthrough} if $args->{passthrough};
    }
    return;
}

sub add_call_debug {
    my ($c, $req_storage, $api_response) = @_;
    if ($c->stash('debug') && $req_storage) {
        $api_response->{debug} = {
            time   => 1000 * Time::HiRes::tv_interval($req_storage->{tv}),
            method => $req_storage->{method},
        };
    }
    return;
}

sub log_call_timing_sent {
    my ($c, $req_storage) = @_;
    if ($req_storage && $req_storage->{tv} && $req_storage->{method}) {
        DataDog::DogStatsd::Helper::stats_timing(
            'bom_websocket_api.v_3.rpc.call.timing.sent',
            1000 * Time::HiRes::tv_interval($req_storage->{tv}),
            {tags => ["rpc:$req_storage->{method}"]});
    }
    return;
}

my %rate_limit_map = (
    ping_real                      => '',
    time_real                      => '',
    portfolio_real                 => 'websocket_call_expensive',
    statement_real                 => 'websocket_call_expensive',
    profit_table_real              => 'websocket_call_expensive',
    proposal_real                  => 'websocket_real_pricing',
    proposal_open_contract_real    => 'websocket_real_pricing',
    verify_email_real              => 'websocket_call_email',
    buy_real                       => 'websocket_real_pricing',
    sell_real                      => 'websocket_real_pricing',
    buy_virtual                    => 'virtual_buy_transaction',
    sell_virtual                   => 'virtual_sell_transaction',
    reality_check_real             => 'websocket_call_expensive',
    ping_virtual                   => '',
    time_virtual                   => '',
    portfolio_virtual              => 'websocket_call_expensive',
    statement_virtual              => 'websocket_call_expensive',
    profit_table_virtual           => 'websocket_call_expensive',
    proposal_virtual               => 'websocket_call_pricing',
    proposal_open_contract_virtual => 'websocket_call_pricing',
    verify_email_virtual           => 'websocket_call_email',
);

sub reached_limit_check {
    my ($c, $category, $is_real) = @_;

    my $limiting_service = $rate_limit_map{
        $category . '_'
            . (
            ($is_real)
            ? 'real'
            : 'virtual'
            )} // 'websocket_call';
    if ($limiting_service
        and not $c->rate_limitations->within_rate_limits($limiting_service, 'does-not-matter'))
    {
        stats_inc("bom_websocket_api.v_3.call.ratelimit.hit.$limiting_service", {tags => ["app_id:" . $c->app_id]});
        $c->rate_limitations_save;
        return 1;
    }
    return;
}

# Set JSON Schema default values for fields which are missing and have default.
sub _set_defaults {
    my ($validator, $args) = @_;

    my $properties = $validator->{in_validator}->schema->{properties};

    foreach my $k (keys %$properties) {
        $args->{$k} = $properties->{$k}->{default} if not exists $args->{$k} and $properties->{$k}->{default};
    }
    return;
}

sub before_forward {
    my ($c, $req_storage) = @_;

    $req_storage->{origin_args} = {%{$req_storage->{args}}};
    my $args = $req_storage->{args};

    # For authorized calls that are heavier we will limit based on loginid
    # For unauthorized calls that are less heavy we will use connection id.
    # None are much helpful in a well prepared DDoS.
    my $is_real = $c->stash('loginid') && !$c->stash('is_virtual');
    my $category = $req_storage->{name};
    if (reached_limit_check($c, $category, $is_real)) {
        return $c->new_error($category, 'RateLimit', $c->l('You have reached the rate limit for [_1].', $category));
    }

    my $input_validation_result = $req_storage->{in_validator}->validate($args);
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
        if ($details->{req_id}) {
            delete $args->{req_id};
        }
        return $c->new_error($req_storage->{name}, 'InputValidationFailed', $message, $details);
    }

    _set_defaults($req_storage, $args);

    my $tag = 'origin:';
    if (my $origin = $c->req->headers->header("Origin")) {
        if ($origin =~ /https?:\/\/([a-zA-Z0-9\.]+)$/) {
            $tag = "origin:$1";
        }
    }

    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.' . $req_storage->{name}, {tags => [$tag]});
    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.all', {tags => [$tag, "category:$req_storage->{name}"]});

    my $loginid = $c->stash('loginid');
    if ($req_storage->{require_auth} and not $loginid) {
        return $c->new_error($req_storage->{name}, 'AuthorizationRequired', $c->l('Please log in.'));
    }

    if ($req_storage->{require_auth} and not(grep { $_ eq $req_storage->{require_auth} } @{$c->stash('scopes') || []})) {
        return $c->new_error($req_storage->{name}, 'PermissionDenied',
            $c->l('Permission denied, requires [_1] scope.', $req_storage->{require_auth}));
    }

    if ($loginid) {
        my $account_type = $c->stash('is_virtual') ? 'virtual' : 'real';
        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.authenticated_call.all',
            {tags => [$tag, $req_storage->{name}, "account_type:$account_type"]});
    }

    return;
}

sub get_rpc_url {
    my ($c, $req_storage) = @_;

    $req_storage->{url} = $ENV{RPC_URL} || $c->app->config->{rpc_url};
    return;
}

sub get_pricing_rpc_url {
    my $c = shift;

    return $ENV{PRICING_RPC_URL} || $c->app->config->{pricing_rpc_url};
}

sub output_validation {
    my ($c, $req_storage, $api_response) = @_;

    return unless $req_storage;

    # Because of the implementation of "Mojo::WebSocketProxy::Dispatcher", a request reached
    # rate limit will still be validated, which should be ignored.
    if (ref $api_response eq 'HASH' and exists $api_response->{error}) {
        return if exists $api_response->{error}{code} and $api_response->{error}{code} eq 'RateLimit';
    }

    if ($req_storage->{out_validator}) {
        my $output_validation_result = $req_storage->{out_validator}->validate($api_response);
        if (not $output_validation_result) {
            my $error = join(" - ", $output_validation_result->errors);
            $c->app->log->warn("Invalid output parameter for [ " . JSON::to_json($api_response) . " error: $error ]");
            %$api_response = %{
                $c->new_error($req_storage->{msg_type} || $req_storage->{name},
                    'OutputValidationFailed', $c->l("Output validation failed: ") . $error)};
        }
    }

    return;
}

sub forget_all {
    my $c = shift;

    Binary::WebSocketAPI::v3::Wrapper::System::_forget_transaction_subscription($c, 'balance');
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_transaction_subscription($c, 'transaction');
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_transaction_subscription($c, 'proposal_open_contract');

    Binary::WebSocketAPI::v3::Wrapper::System::_forget_all_pricing_subscriptions($c, 'proposal');
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_all_pricing_subscriptions($c, 'proposal_open_contract');

    Binary::WebSocketAPI::v3::Wrapper::System::_forget_feed_subscription($c, 'ticks');
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_feed_subscription($c, 'candles');

    Binary::WebSocketAPI::v3::Wrapper::System::_forget_all_proposal_array($c);

    return;
}

sub error_check {
    my ($c, $req_storage, $rpc_response) = @_;
    my $result = $rpc_response->result;
    if (ref($result) eq 'HASH' && $result->{error}) {
        $c->stash->{introspection}{last_rpc_error} = $result->{error};
        $req_storage->{close_connection} = 1 if $result->{error}->{code} eq 'InvalidAppID';
    }
    return;
}

sub close_bad_connection {
    my ($c, $req_storage) = @_;
    if ($req_storage->{close_connection}) {
        $c->finish;
    }
    return;
}

sub add_app_id {
    my ($c, $req_storage) = @_;
    $req_storage->{call_params}->{valid_source} = $c->stash('valid_source');
    $req_storage->{call_params}->{source}       = $c->stash('source');
    return;
}

sub add_brand {
    my ($c, $req_storage) = @_;
    $req_storage->{call_params}->{brand} = $c->stash('brand');
    return;
}

sub check_app_id {
    my ($c, $req_storage) = @_;

    # check for app_id, throw error if it's not there
    unless (defined $c->stash('source')) {
        try {
            Path::Tiny::path('/var/log/httpd/missing_app_id.log')
                ->append('No app id, ip is ' . $c->stash('client_ip') . ' country is ' . $c->stash('country_code'));
        };
        return $c->new_error($req_storage->{name}, 'AccessForbidden',
            $c->l('App id is mandatory to access our api. Please register your application.'));
    }
    return;
}

sub on_client_connect {
    my ($c) = @_;
    # We use a weakref in case the disconnect is never called
    warn "Client connect request but $c is already in active connection list" if exists $c->app->active_connections->{$c};
    Scalar::Util::weaken($c->app->active_connections->{$c} = $c);

    $c->app->stat->{cumulative_client_connections}++;
    $c->rate_limitations_load;
    return;
}

sub on_client_disconnect {
    my ($c) = @_;
    warn "Client disconnect request but $c is not in active connection list" unless exists $c->app->active_connections->{$c};

    delete $c->app->active_connections->{$c};
    $c->rate_limitations_save;
    forget_all();
    my $timer_id = $c->stash->{rate_limitations_timer};
    Mojo::IOLoop->remove($timer_id) if $timer_id;

    return;
}

sub introspection_before_forward {
    my ($c, $req_storage) = @_;
    my %args_copy = %{$req_storage->{origin_args}};
    $c->stash->{introspection}{last_call_received} = \%args_copy;

    $c->stash->{introspection}{msg_type}{received}{$req_storage->{method}}++;
    use bytes;
    $c->stash->{introspection}{received_bytes} += bytes::length(Dumper($req_storage->{origin_args}));
    return;
}

sub introspection_before_send_response {
    my ($c, $req_storage, $api_response) = @_;
    my %copy = %{$api_response};
    $c->stash->{introspection}{last_message_sent} = \%copy;
    $c->stash->{introspection}{msg_type}{sent}{$api_response->{msg_type}}++;
    use bytes;
    $c->stash->{introspection}{sent_bytes} += bytes::length(Dumper($api_response));
    return;
}

1;
