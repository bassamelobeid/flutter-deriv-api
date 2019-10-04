package Binary::WebSocketAPI::Hooks;

use strict;
use warnings;

use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use Future;
use JSON::MaybeXS;
use Mojo::IOLoop;
use Path::Tiny;
use Try::Tiny;
use Data::Dumper;
use JSON::Validator;
use Clone;
use Log::Any qw($log);
use DataDog::DogStatsd::Helper qw(stats_inc);
use Path::Tiny;
use Net::Address::IP::Local;
#  module is loaded on server start and shared across connections
#  %schema_cache is added onto as each unique request type is received.
#  by the _load_schema sub in this module
my %schema_cache;
my $schemas_base = '/home/git/regentmarkets/binary-websocket-api/config/v3/';

my $json = JSON::MaybeXS->new;

=head2 _load_schema

Description
Gets  the json validation schema for the call types so  we can pass to send so that they are processed by the hooks.
This is required as they are not stashed.

=over 4

=item  * C<request_type>   string - the name of the request type eg 'Proposal_array'

=item  * C<direction>   string - send or receive, defaults to receive

=back

Returns version 4 schema

=cut

sub _load_schema {
    my ($request_type, $direction) = @_;

    return if $request_type eq 'error';
    $direction //= 'receive';
    my $schema;

    #sometimes the msg_type does not match the schema dir name
    #mapped here msg_type on the left directory on the right
    my %schema_mapping = (
        tick    => 'ticks',
        history => 'ticks_history',
        candles => 'ticks_history',
        ohlc    => 'ticks_history',

    );
    $request_type = $schema_mapping{$request_type} || $request_type;
    if (!exists $schema_cache{$request_type}{$direction}) {
        my $schema_path = $schemas_base . $request_type . '/' . $direction . '.json';
        if (!-e $schema_path) {
            $log->warnf('no schema found  for %s', $request_type);
            return {};
        }
        $schema = decode_json(path($schema_path)->slurp);
        $schema_cache{$request_type}{$direction} = $schema;
    }
    return $schema_cache{$request_type}{$direction};
}

sub start_timing {
    my ($c, $req_storage) = @_;
    if ($req_storage) {
        $req_storage->{tv} = [Time::HiRes::gettimeofday];

        if (_is_profiling($c)) {
            $req_storage->{call_params}->{is_profiling} = 1;
            $req_storage->{passthrough}{profile} //= {
                pid                => $$,
                active_connections => Binary::WebSocketAPI::BalanceConnections::get_active_connections_count(),
                server_name        => $c->server_name,
                server_ip          => Net::Address::IP::Local->public,
                ws_send_wsproc     => scalar Time::HiRes::gettimeofday,
            };
        }
    }
    return;
}

sub cleanup_stored_contract_ids {
    my $c              = shift;
    my $last_contracts = $c->stash('last_contracts') // {};
    my $now            = time;
    # see Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_store_last_contract_id
    # keep contract bought in last 60 sec, update stash only if contract list changed
    # Here the `$last_contracts` is a hashref which refer to the same object in stash when $c->stash('last_contracts') is true, altering it will alter data in stash too.
    # If $c->stash('last_contract') is false, then the `delete` action in the next line will do nothing.
    delete @{$last_contracts}{grep { ($now - $last_contracts->{$_}) > 60 } keys %$last_contracts};
    return;
}

sub log_call_timing_before_forward {
    my ($c, $req_storage) = @_;

    if ($req_storage && $req_storage->{tv} && $req_storage->{method}) {
        DataDog::DogStatsd::Helper::stats_timing(
            'bom_websocket_api.v_3.rpc.call.timing.before_forward',
            1000 * Time::HiRes::tv_interval($req_storage->{tv}),
            {tags => ["rpc:$req_storage->{method}"]});
    }

    $req_storage->{passthrough}{profile}{wsproc_send_rpc} = Time::HiRes::gettimeofday
        if _is_profiling($c);

    return;
}

sub log_call_timing {
    my ($c, $req_storage) = @_;
    my $tags = ["rpc:$req_storage->{method}", "app_name:" . ($c->stash('app_name') || ''), "app_id:" . ($c->stash('source') || ''),];

    # extra tagging for buy for better visualization
    push @$tags, 'market:' . $c->stash('market') if $req_storage->{method} eq 'buy' and $c->stash('market');
    DataDog::DogStatsd::Helper::stats_timing(
        'bom_websocket_api.v_3.rpc.call.timing',
        1000 * Time::HiRes::tv_interval($req_storage->{tv}),
        {tags => $tags});
    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.rpc.call.count', {tags => $tags});
    return;
}

sub log_call_timing_connection {
    my ($c, $req_storage, $rpc_response) = @_;

    if (   ref($rpc_response->result) eq "HASH"
        && (my $rpc_time  = delete $rpc_response->result->{rpc_time})
        && (my $auth_time = delete $rpc_response->result->{auth_time}))
    {
        my $tags = ["rpc:$req_storage->{method}"];
        push @$tags, "market:" . $c->stash('market') if $req_storage->{method} eq 'buy' && $c->stash('market');
        DataDog::DogStatsd::Helper::stats_timing(
            'bom_websocket_api.v_3.rpc.call.timing.connection',
            1000 * Time::HiRes::tv_interval($req_storage->{tv}) - $rpc_time - $auth_time,
            {tags => $tags});

        DataDog::DogStatsd::Helper::stats_timing('bom_websocket_api.v_3.pre_rpc.call.timing.', $auth_time, {tags => $tags});
    }

    if (_is_profiling($c)) {
        $req_storage->{passthrough}{profile} = {
            $req_storage->{passthrough}{profile}->%*,
            $rpc_response->result->{passthrough}{profile}->%*,
            wsproc_receive_rpc => scalar Time::HiRes::gettimeofday,
        };
        delete $rpc_response->result->{passthrough};
    }

    return;
}

sub add_req_data {
    my ($c, $req_storage, $api_response) = @_;
    # api_response being a string means error happened.
    die "api_response is not hashref: $api_response" unless ref($api_response) eq 'HASH';

    my $args = {};
    if ($req_storage) {
        $args = $req_storage->{origin_args} || $req_storage->{args};
        $api_response->{echo_req} = _sanitize_echo($args, $api_response->{msg_type});
    } elsif (defined $api_response->{echo_req}) {
        $args = $api_response->{echo_req};
    }

    $api_response->{req_id}      = $args->{req_id}      if defined $args->{req_id};
    $api_response->{passthrough} = $args->{passthrough} if defined $args->{passthrough};

    $api_response->{passthrough}{profile} = {$req_storage->{passthrough}{profile}->%*}
        if _is_profiling($c);

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
        my $tags = ["rpc:$req_storage->{method}"];
        push @$tags, "market:" . $c->stash('market') if $req_storage->{method} eq 'buy' and $c->stash('market');
        DataDog::DogStatsd::Helper::stats_timing(
            'bom_websocket_api.v_3.rpc.call.timing.sent',
            1000 * Time::HiRes::tv_interval($req_storage->{tv}),
            {tags => $tags});
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
    request_report_real            => 'websocket_call_email',
    request_report_virtual         => 'websocket_call_email',
    account_statistics_real        => 'websocket_call_expensive',
    account_statistics_virtual     => 'websocket_call_expensive',
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
    if ($limiting_service) {
        my $f = $c->check_limits($limiting_service);
        $f->on_fail(
            sub {
                stats_inc("bom_websocket_api.v_3.call.ratelimit.hit.$limiting_service", {tags => ["app_id:" . ($c->app_id // 'undef')]});
            });
        return $f;
    }
    return Future->done;
}

# Set JSON Schema default values for fields which are missing and have default.
sub _set_defaults {
    my ($validator, $args) = @_;

    my $properties = $validator->{schema_send}->{properties};

    foreach my $k (keys %$properties) {
        next if exists $args->{$k};
        $args->{$k} = $properties->{$k}->{default} if $properties->{$k}->{default};
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

    return reached_limit_check($c, $category, $is_real)->then(
        sub {
            my $error = _validate_schema_error($req_storage->{schema_send}, $args);
            if ($error) {
                my $message = $c->l('Input validation failed: ') . join(', ', (keys %{$error->{details}}, @{$error->{general}}));
                return Future->fail($c->new_error($req_storage->{name}, 'InputValidationFailed', $message, $error->{details}));
            }

            _set_defaults($req_storage, $args);

            my $tag = 'origin:';
            # if connection is early closed there is no $c->req
            return Future->fail($c->new_error($category, 'RateLimit', $c->l('Connection closed'))) unless $c->tx;
            if (my $origin = $c->req->headers->header("Origin")) {
                if ($origin =~ /https?:\/\/([a-zA-Z0-9\.]+)$/) {
                    $tag = "origin:$1";
                }
            }

            DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.' . $req_storage->{name}, {tags => [$tag]});
            DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.all', {tags => [$tag, "category:$req_storage->{name}"]});

            my $loginid = $c->stash('loginid');
            if ($req_storage->{require_auth} and not $loginid) {
                return Future->fail($c->new_error($req_storage->{name}, 'AuthorizationRequired', $c->l('Please log in.')));
            }

            if ($req_storage->{require_auth} and not(grep { $_ eq $req_storage->{require_auth} } @{$c->stash('scopes') || []})) {
                return Future->fail(
                    $c->new_error(
                        $req_storage->{name}, 'PermissionDenied', $c->l('Permission denied, requires [_1] scope.', $req_storage->{require_auth})));
            }

            if ($loginid) {
                my $account_type = $c->stash('is_virtual') ? 'virtual' : 'real';
                DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.authenticated_call.all',
                    {tags => [$tag, $req_storage->{name}, "account_type:$account_type"]});
            }
            return Future->done;
        },
        sub {
            Future->fail($c->new_error($category, 'RateLimit', $c->l('You have reached the rate limit for [_1].', $category)));
        });
}

sub _rpc_suffix {
    my ($c) = @_;

    my $app_id    = $c->app_id // '';
    my $processor = $Binary::WebSocketAPI::DIVERT_APP_IDS{$app_id};
    my $suffix    = $processor ? '_' . $processor : '';
    unless (exists $c->app->config->{"rpc_url" . $suffix}) {
        $log->warn("Suffix $suffix not found in config for app ID $app_id\n");
        $suffix = '';
    }
    return $suffix;
}

sub get_rpc_url {
    my ($c) = @_;

    my $suffix = _rpc_suffix($c);
    return $ENV{RPC_URL} || $c->app->config->{"rpc_url" . $suffix};
}

sub assign_rpc_url {
    my ($c, $req_storage) = @_;

    $req_storage->{url} = get_rpc_url($c);
    return;
}

=head2 assign_ws_backend

Saves the configured B<backend> of an API call into the request storage, before forwarding it to RPC.
It is a necessary step for http/queue backend switching.

=cut

sub assign_ws_backend {
    my ($c, $req_storage) = @_;
    my $action = $Binary::WebSocketAPI::WS_ACTIONS->{$req_storage->{method}};
    $req_storage->{backend} = $action->{backend} if $action->{backend};
    return;
}

sub get_doc_auth_s3_conf {
    my $c = shift;
    my $access_key = $ENV{DOCUMENT_AUTH_S3_ACCESS} || $c->app->config->{document_auth_s3}->{aws_access_key_id} || die 'S3 Configuration Unavailable';
    my $secret_key =
        $ENV{DOCUMENT_AUTH_S3_SECRET} || $c->app->config->{document_auth_s3}->{aws_secret_access_key} || die 'S3 Configuration Unavailable';
    my $bucket = $ENV{DOCUMENT_AUTH_S3_BUCKET} || $c->app->config->{document_auth_s3}->{aws_bucket} || die 'S3 Configuration Unavailable';
    return {
        access_key => $access_key,
        secret_key => $secret_key,
        bucket     => $bucket,
    };
}

sub output_validation {
    my ($c, $req_storage, $api_response) = @_;

    # No validation done of top level errors EG "unrecognised request etc.
    if (ref $api_response eq 'HASH' and exists $api_response->{error}) {
        return if exists $api_response->{error}{code};
    }

    my $schema;
    if ($api_response->{msg_type}) {
        $schema = _load_schema($api_response->{msg_type});
    }

    my $error = _validate_schema_error($schema, $api_response);

    if ($error) {
        my $error_msg = join(" - ", (map { "$_:$error->{details}{$_}" } keys %{$error->{details}}), @{$error->{general}});
        $log->error("Schema validation failed for our own output [ "
                . $json->encode($api_response)
                . " error: $error_msg ], make sure backend are aware of this error!, schema may need adjusting");
        %$api_response = %{
            $c->new_error($req_storage->{msg_type} || $req_storage->{name},
                'OutputValidationFailed', $c->l("Output validation failed: ") . $error_msg)};
    }

    return;
}

sub forget_all {
    my $c = shift;
    # TODO I guess 'buy' type should be added here.
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_transaction_subscription($c, $_) for qw(balance transaction sell);
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_all_pricing_subscriptions($c, $_) for qw(proposal proposal_open_contract proposal_array);
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_feed_subscription($c, $_) for qw(ticks candles);
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_all_website_status($c);

    return;
}

sub error_check {
    my ($c, $req_storage, $rpc_response) = @_;
    my $result = $rpc_response->result;
    if (ref($result) eq 'HASH' && $result->{error}) {
        $c->stash->{introspection}{last_rpc_error} = $result->{error};
        $req_storage->{close_connection} = 1 if $result->{error}->{code} eq 'InvalidAppID';
        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.error', {tags => ["rpc:$req_storage->{method}"]});
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
    $req_storage->{call_params}->{valid_source}               = $c->stash('valid_source');
    $req_storage->{call_params}->{source}                     = $c->stash('source');
    $req_storage->{call_params}->{source_bypass_verification} = $c->stash('source_bypass_verification');
    return;
}

sub add_log_config {
    my ($c, $req_storage) = @_;
    $req_storage->{call_params}->{logging} = \%Binary::WebSocketAPI::RPC_LOGGING;
    return;
}

sub add_brand {
    my ($c, $req_storage) = @_;
    $req_storage->{call_params}->{brand} = $c->stash('brand');
    return;
}

sub _on_sanity_failed {
    my ($c) = @_;
    my $client_ip = $c->stash->{client_ip};
    my $tags = ["client_ip:$client_ip", "app_name:" . ($c->stash('app_name') || ''), "app_id:" . ($c->stash('source') || ''),];
    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.sanity_check_failed.count', {tags => $tags});

    return;
}

sub on_client_connect {
    my ($c) = @_;
    # We use a weakref in case the disconnect is never called
    $log->warn("Client connect request but $c is already in active connection list") if exists $c->app->active_connections->{$c};
    Scalar::Util::weaken($c->app->active_connections->{$c} = $c);

    $c->app->stat->{cumulative_client_connections}++;
    $c->on(encoding_error => \&_handle_error);
    $c->on(sanity_failed  => \&_on_sanity_failed);

    return;
}

sub on_client_disconnect {
    my ($c) = @_;

    $log->warn("Client disconnect request but $c is not in active connection list") unless exists $c->app->active_connections->{$c};
    forget_all($c);

    delete $c->app->active_connections->{$c};
    if (my $tx = $c->tx) {
        $tx->unsubscribe('sanity_failed');
    }

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

    $api_response->{passthrough}{profile}{ws_receive_wsproc} = Time::HiRes::gettimeofday
        if _is_profiling($c);
    return;
}

=head2 filter_sensitive_fields

Changes the value of any attribute that has a C<{"sensitive" : 1}> attribute set in the schema
note that "sensitive" is not a standard JSON schema attribute but JSON validators will ignore non
standard attributes.
Also Note that this updates the reference  to the data so make a copy of the data if you do not want it modified.
Takes the following arguments as parameters

=over 4

=item C<$schema> HashRef JSON schema as a  HashRef

=item C<$data> HashRef API data matching the JSON schema

=back

Returns undef

=cut

sub filter_sensitive_fields {
    my ($schema, $data) = @_;
    my $properties = $schema->{'properties'};
    my $redact_str = '<not shown>';

    foreach my $attr (keys(%{$properties})) {
        my $current_attr = $properties->{$attr};
        my $attr_type = $current_attr->{'type'} // '';

        if (ref($current_attr) eq 'HASH') {
            if ($attr_type eq 'object') {
                filter_sensitive_fields($current_attr, $data->{$attr});
            } elsif ($attr_type eq 'array' && ref($current_attr->{items}) eq 'HASH' && ($current_attr->{items}{type} // '') eq 'object') {
                filter_sensitive_fields($current_attr->{items}, $_) for $data->{$attr}->@*;
            }
        }

        if (defined($data->{$attr}) && $current_attr->{'sensitive'}) {
            if ($current_attr->{type} eq 'array') {
                my $array_count    = scalar(@{$data->{$attr}});
                my @filtered_array = (($redact_str) x $array_count);
                $data->{$attr} = \@filtered_array;
            } else {
                $data->{$attr} = $redact_str;
            }
        }
    }
    return undef;
}

=head2 _validate_schema_error

Checks sent and received API data for validation against our JSON schema's
Takes the following arguments as parameters

=over 4

=item  C<$schema> HashRef version 4 of the schema

=item  C<$args> HashRef Data from API call

=back

Returns an HashRef on error or undef if no error

 {
    details => { "attribute name" => "Error message" },
    general => [ "error message one" ,  "error message two" ]
 }

=cut

sub _validate_schema_error {
    my ($schema, $args) = @_;
    my $validator = JSON::Validator->new();
    my @errors;
    # This statement will coerce items like "1" into a integer this allows for better compatibility with the existing schema
    $validator->coerce(
        booleans => 1,
        numbers  => 1,
        strings  => 1
    );
    @errors = $validator->schema($schema)->validate($args);
    return undef unless scalar(@errors);    #passed Version 4 Check

    my (%details, @general);

    foreach my $error (@errors) {
        if ($error->path =~ /\/(.+)$/) {
            $details{$1} = $error->message;
        } else {
            push @general, $error->message;
        }
    }

    return {
        details => \%details,
        general => \@general
    };

}

sub _handle_error {
    my ($c, $all_data) = @_;
    my $app_id = $c->{stash}->{source};

    my %error_mapping = (
        INVALID_UTF8    => 'websocket_proxy.utf8_decoding.failure',
        INVALID_UNICODE => 'websocket_proxy.unicode_normalisation.failure',
        INVALID_JSON    => 'websocket_proxy.malformed_json.failure'
    );

    stats_inc($error_mapping{$all_data->{details}->{error_code}}, {tags => ['error_code:1007']});
    $log->errorf("[ERROR - %s] APP ID: %s Details: %s", $all_data->{details}->{error_code}, $app_id, $all_data->{details}->{reason});
    $c->finish;
    return;
}

=head2 _sanitize_echo

Final processing of echo_req to ensure we don't send anything sensitive in response.
Attributes marked with "sensitive" is in the send schema will be redacted.

=cut

sub _sanitize_echo {
    my ($params, $msg_type) = @_;

    my $schema = _load_schema($msg_type, 'send');
    filter_sensitive_fields($schema, $params);

    return $params;
}

=head2 _is_profiling

Returns true when the C<X-Profiling> HTTP header is set to a predefined secret value
in the request.
Missing or incorrect header value will return false.

=cut

sub _is_profiling {
    my ($c) = @_;
    return if !$c->tx || $c->tx->is_finished;
    my $profiling = $c->req->headers->header('X-Profiling') // '';
    return $profiling eq '547a52075cb11e8404cd207a5612dd75';
}

sub check_app_id {
    my ($c) = @_;
    if (exists $Binary::WebSocketAPI::BLOCK_APP_IDS{$c->app_id}) {
        $c->finish(403 => 'AccessRestricted');
        return;
    }

}

1;
