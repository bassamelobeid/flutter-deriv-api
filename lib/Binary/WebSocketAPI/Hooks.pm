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
use JSON::Schema;
use JSON::Validator;
use Clone;
#set up a specific logger for the V3 to v4 logging
use Log::Any '$schema_log', category => 'schema_log';
use Log::Any::Adapter;
Log::Any::Adapter->set({category => 'schema_log'}, 'File', '/var/lib/binary/v4_v3_schema_fails.log');
use Log::Any qw($log);
use DataDog::DogStatsd::Helper qw(stats_inc);

my $json = JSON::MaybeXS->new;

sub start_timing {
    my (undef, $req_storage) = @_;
    if ($req_storage) {
        $req_storage->{tv} = [Time::HiRes::gettimeofday];
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
    my (undef, $req_storage, $rpc_response) = @_;
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
    my (undef, $req_storage, $api_response) = @_;

    my $args = {};
    if ($req_storage) {
        $args = $req_storage->{origin_args} || $req_storage->{args};
        $api_response->{echo_req} = $args;
    } elsif (defined $api_response->{echo_req}) {
        $args = $api_response->{echo_req};
    }

    $api_response->{req_id}      = $args->{req_id}      if defined $args->{req_id};
    $api_response->{passthrough} = $args->{passthrough} if defined $args->{passthrough};
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
    my (undef, $req_storage) = @_;
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
    cashier_password_real          => 'websocket_call_password',
    cashier_password_virtual       => 'websocket_call_password',
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
            my $caller_info = {
                loginid => $c->stash('loginid'),
                app_id  => $c->app_id
            };
            my $error = _validate_schema_error($req_storage->{schema_send}, $req_storage->{schema_send_v3}, $args, $caller_info);
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
        warn "Suffix $suffix not found in config for app ID $app_id\n";
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
    return unless $req_storage;

    # Because of the implementation of "Mojo::WebSocketProxy::Dispatcher", a request reached
    # rate limit will still be validated, which should be ignored.
    if (ref $api_response eq 'HASH' and exists $api_response->{error}) {
        return if exists $api_response->{error}{code} and $api_response->{error}{code} eq 'RateLimit';
    }
    if ($req_storage->{schema_receive}) {

        my $caller_info = {
            loginid => $c->stash('loginid'),
            app_id  => $c->stash('app_id')};
        my $error = _validate_schema_error($req_storage->{schema_receive}, $req_storage->{schema_receive_v3}, $api_response, $caller_info);
        if ($error) {
            my $error_msg = join(" - ", (map { "$_:$error->{details}{$_}" } keys %{$error->{details}}), @{$error->{general}});
            $c->app->log->warn("Invalid output parameter for [ " . $json->encode($api_response) . " error: $error_msg ]");
            %$api_response = %{
                $c->new_error($req_storage->{msg_type} || $req_storage->{name},
                    'OutputValidationFailed', $c->l("Output validation failed: ") . $error_msg)};
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
    warn "Client connect request but $c is already in active connection list" if exists $c->app->active_connections->{$c};
    Scalar::Util::weaken($c->app->active_connections->{$c} = $c);

    $c->app->stat->{cumulative_client_connections}++;
    $c->on(encoding_error => \&_handle_error);
    $c->on(sanity_failed  => \&_on_sanity_failed);

    return;
}

sub on_client_disconnect {
    my ($c) = @_;

    warn "Client disconnect request but $c is not in active connection list" unless exists $c->app->active_connections->{$c};
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
    my ($c, undef, $api_response) = @_;
    my %copy = %{$api_response};
    $c->stash->{introspection}{last_message_sent} = \%copy;
    $c->stash->{introspection}{msg_type}{sent}{$api_response->{msg_type}}++;
    use bytes;
    $c->stash->{introspection}{sent_bytes} += bytes::length(Dumper($api_response));
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
    foreach my $attr (keys(%{$properties})) {
        my $current_attr = $properties->{$attr};
        if (ref($current_attr) eq 'HASH' && ($current_attr->{'type'} // '') eq 'object') {
            filter_sensitive_fields($current_attr, $data->{$attr});
        }
        if (defined($data->{$attr}) && $current_attr->{'sensitive'}) {
            if ($current_attr->{type} eq 'array') {
                my $array_count    = scalar(@{$data->{$attr}});
                my @filtered_array = (('### Sensitive ###') x $array_count);
                $data->{$attr} = \@filtered_array;
            } else {
                $data->{$attr} = '### Sensitive ###';
            }
        }
    }
    return undef;
}

=head2 _validate_schema_error

Checks sent and received API data for validation against our JSON schema's
Currently from 11/2018 it first validates against v4 of the schema and if it fails it will try against v3
if it passes V3 we log the message, error and the source.  The idea is to capture the failures and 
determine if we need any action before enforcing v4 
Takes the following arguments as parameters

=over 4

=item  C<$schema> HashRef version 4 of the schema 

=item  C<$schema_v3> HashRef version 3 of the schema 

=item  C<$args> HashRef Data from API call 

=item  C<$caller_info> HashRef  containing extra information for logs messages with keys "loginid", "app_id"


=back

Returns an HashRef on error or undef if no error

 {
    details => { "attribute name" => "Error message" },
    general => [ "error message one" ,  "error message two" ]
 }
   

=cut

sub _validate_schema_error {
    my ($schema, $schema_v3, $args, $caller_info) = @_;
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

    if (!$schema_v3) {
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

    #check against version 3 of JSON Schema
    my $v3_result = JSON::Schema->new($schema_v3, format => \%JSON::Schema::FORMATS)->validate($args);

    # This result object uses overload to mimic a boolean, true means no error, false means error
    if ($v3_result) {
        #Failed v4 check but passed V3 so log it and let it through
        my $cloned_args = Clone::clone($args);
        filter_sensitive_fields($schema, $cloned_args);
        my $message = {
            data         => $cloned_args,
            errors       => "@errors",
            caller       => $caller_info,
            schema_title => $schema->{title}};
        $schema_log->warn($message);
        return undef;
    } else {
        my (%details, @general);
        foreach my $err ($v3_result->errors) {
            if ($err->property =~ /\$\.(.+)$/) {
                @details{$1} = $err->message;
            } else {
                push @general, $err->message;
            }
        }

        #failed version 4 and 3 check return the version 4 error message.
        return {
            details => \%details,
            general => \@general
        };
    }
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

1;
