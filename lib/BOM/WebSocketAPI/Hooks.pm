package BOM::WebSocketAPI::Hooks;

use strict;
use warnings;
use Try::Tiny;
use Data::UUID;
use RateLimitations qw(within_rate_limits);
use BOM::System::Config;

sub start_timing {
    my ($c, $req_storage) = @_;
    if ($req_storage) {
        $req_storage->{tv} = [Time::HiRes::gettimeofday];
    }
    return;
}

sub log_call_timing {
    my ($c, $req_storage) = @_;
    DataDog::DogStatsd::Helper::stats_timing(
        'bom_websocket_api.v_3.rpc.call.timing',
        1000 * Time::HiRes::tv_interval($req_storage->{tv}),
        {tags => ["rpc:$req_storage->{method}"]});
    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.rpc.call.count', {tags => ["rpc:$req_storage->{method}"]});
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
        $api_response->{echo_req} = $req_storage->{args};
        $api_response->{req_id} = $req_storage->{args}->{req_id} if $req_storage->{args}->{req_id};
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
    pricing_table_real             => 'websocket_real_pricing',
    proposal_open_contract_real    => 'websocket_real_pricing',
    verify_email_real              => 'websocket_call_email',
    buy_real                       => 'websocket_real_pricing',
    sell_real                      => 'websocket_real_pricing',
    reality_check_real             => 'websocket_call_expensive',
    ping_virtual                   => '',
    time_virtual                   => '',
    portfolio_virtual              => 'websocket_call_expensive',
    statement_virtual              => 'websocket_call_expensive',
    profit_table_virtual           => 'websocket_call_expensive',
    proposal_virtual               => 'websocket_call_pricing',
    pricing_table_virtual          => 'websocket_call_pricing',
    proposal_open_contract_virtual => 'websocket_call_pricing',
    verify_email_virtual           => 'websocket_call_email',
);

sub reached_limit_check {
    my ($consumer, $category, $is_real) = @_;

    my $limiting_service = $rate_limit_map{
        $category . '_'
            . (
            ($is_real)
            ? 'real'
            : 'virtual'
            )} // 'websocket_call';
    if (
        $limiting_service
        and not within_rate_limits({
                service  => $limiting_service,
                consumer => $consumer,
            }))
    {
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

    my $args = $req_storage->{args};
    if (not $c->stash('connection_id')) {
        $c->stash('connection_id' => Data::UUID->new()->create_str());
    }

    $req_storage->{handle_t0} = [Time::HiRes::gettimeofday];

    # For authorized calls that are heavier we will limit based on loginid
    # For unauthorized calls that are less heavy we will use connection id.
    # None are much helpful in a well prepared DDoS.
    my $consumer = $c->stash('loginid') || $c->stash('connection_id');
    my $is_real = $c->stash('loginid') && !$c->stash('is_virtual');
    my $category = $req_storage->{name};
    if (reached_limit_check($consumer, $category, $is_real)) {
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

    my $url = $ENV{RPC_URL} || 'http://127.0.0.1:5005/';
    if (BOM::System::Config::env eq 'production') {
        if (BOM::System::Config::node->{node}->{www2}) {
            $url = 'http://internal-rpc-www2-703689754.us-east-1.elb.amazonaws.com:5005/';
        } else {
            $url = 'http://internal-rpc-1484966228.us-east-1.elb.amazonaws.com:5005/';
        }
    }

    $req_storage->{url} = $url;

    return;
}

sub output_validation {
    my ($c, $req_storage, $api_response) = @_;

    return unless $req_storage;

    my $args                     = $req_storage->{args};
    my $output_validation_result = $req_storage->{out_validator}->validate($api_response);
    if (not $output_validation_result) {
        my $error = join(" - ", $output_validation_result->errors);
        $c->app->log->warn("Invalid output parameter for [ " . JSON::to_json($api_response) . " error: $error ]");
        %$api_response = %{$c->new_error($req_storage->{category}, 'OutputValidationFailed', $c->l("Output validation failed: ") . $error)};
    }

    return;
}

sub init_redis_connections {
    my $c = shift;
    $c->redis;
    $c->redis_pricer;
    return;
}

sub forget_all {
    my $c = shift;
    # stop all recurring
    BOM::WebSocketAPI::v3::Wrapper::System::forget_all($c, {args => {forget_all => 1}});
    delete $c->stash->{redis};
    delete $c->stash->{redis_pricer};
    return;
}

sub clear_db_cache {
    BOM::Database::Rose::DB->db_cache->finish_request_cycle;
    return;
}

1;
