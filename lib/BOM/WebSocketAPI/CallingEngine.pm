package BOM::WebSocketAPI::CallingEngine;

use strict;
use warnings;

use MojoX::JSON::RPC::Client;
use Guard;
use JSON;
use Data::UUID;

# TODO Move to callbacks
# use BOM::System::Config;
# use Time::HiRes;
# use Proc::CPUUsage;
# use feature 'state';
# use DataDog::DogStatsd::Helper;
#
# /TODO Move to callbacks

sub forward {
    my ($c, $rpc_method, $args, $params) = @_;

    $params->{msg_type} ||= $rpc_method;

    return call_rpc(
        $c,
        {
            method   => $rpc_method,
            msg_type => $rpc_method // $params->{msg_type},
            # TODO
            # url => $url,
            call_params     => make_call_params($c, $args, $params),
            rpc_response_cb => rpc_response_cb($c,  $args, $params),
        });
}

sub make_call_params {
    my ($c, $args, $params) = @_;

    my $stash_params   = $params->{stash_params};
    my $call_params_cb = $params->{call_params};
    my $require_auth   = $params->{require_auth};

    my $call_params = {
        args     => $args,
        language => $c->stash('language'),
        country  => $c->stash('country') || $c->country_code,
    };

    if (defined $stash_params) {
        $call_params->{$_} = $c->stash($_) for @$stash_params;
    }
    if ($require_auth && $c->stash('token')) {
        $call_params->{token} = $c->stash('token');
    }
    if (defined $call_params_cb) {
        my $cb_params = $call_params_cb->($c, $args);
        $call_params->{$_} = $cb_params->{$_} for keys %$cb_params;
    }

    return $call_params;
}

sub rpc_response_cb {
    my ($c, $args, $params) = @_;

    my $success_handler = $params->{success};
    my $error_handler   = $params->{error};
    my $msg_type        = $params->{msg_type};

    return sub {
        my $rpc_response = shift;
        if (ref($rpc_response) eq 'HASH' and exists $rpc_response->{error}) {
            $error_handler->($c, $args, $rpc_response) if defined $error_handler;
            return error_api_response($c, $rpc_response, $params);
        } else {
            $success_handler->($c, $args, $rpc_response) if defined $success_handler;
            store_response($c, $rpc_response);
            return success_api_response($c, $rpc_response, $params);
        }
        return;
    };
}

sub store_response {
    my ($c, $rpc_response) = @_;

    if (ref($rpc_response) eq 'HASH' && $rpc_response->{stash}) {
        $c->stash(%{delete $rpc_response->{stash}});
    }
    return;
}

sub success_api_response {
    my ($c, $rpc_response, $params) = @_;

    my $msg_type             = $params->{msg_type};
    my $rpc_response_handler = $params->{response};

    my $api_response = {
        msg_type  => $msg_type,
        $msg_type => $rpc_response,
    };

    # If RPC returned only status then wsapi will return no object
    # TODO Should be removed after RPC's answers will be standardized
    if (ref($rpc_response) eq 'HASH' and keys %$rpc_response == 1 and exists $rpc_response->{status}) {
        $api_response->{$msg_type} = $rpc_response->{status};
    }

    # TODO Should be removed after RPC's answers will be standardized
    my $custom_response;
    if ($rpc_response_handler) {
        return $rpc_response_handler->($rpc_response, $api_response);
    }

    return $api_response;
}

sub error_api_response {
    my ($c, $rpc_response, $params) = @_;

    my $msg_type             = $params->{msg_type};
    my $rpc_response_handler = $params->{response};
    my $api_response         = $c->new_error($msg_type, $rpc_response->{error}->{code}, $rpc_response->{error}->{message_to_client});

    # TODO Should be removed after RPC's answers will be standardized
    my $custom_response;
    if ($rpc_response_handler) {
        return $rpc_response_handler->($rpc_response, $api_response);
    }

    return $api_response;
}

sub call_rpc {
    my $c      = shift;
    my $params = shift;

    my $method      = $params->{method};
    my $msg_type    = $params->{msg_type};
    my $url         = $params->{url};
    my $call_params = $params->{call_params};

    my $rpc_response_cb   = $params->{rpc_response_cb};
    my $max_response_size = $params->{max_response_size};

    # TODO It'll be hooks
    my $before_get_rpc_response_hook  = $params->{before_get_rpc_response};
    my $after_got_rpc_response_hook   = $params->{after_got_rpc_response};
    my $before_send_api_response_hook = $params->{before_send_api_response};
    my $after_sent_api_response_hook  = $params->{after_sent_api_response};
    my $before_call_hook              = $params->{before_call};

    $before_call_hook->($c, $call_params) if $before_call_hook;

    my $client  = MojoX::JSON::RPC::Client->new;
    my $callobj = {
        id     => Data::UUID->new()->create_str(),
        method => $method,
        params => $call_params,
    };

    $client->call(
        $url, $callobj,
        sub {
            my $res = pop;

            $before_get_rpc_response_hook->($c) if $before_get_rpc_response_hook;

            # unconditionally stop any further processing if client is already disconnected
            return unless $c->tx;

            my $client_guard = guard { undef $client };

            my $api_response;
            my %binding = (
                echo_req => $call_params->{args},
                $call_params->{args}->{req_id} ? (req_id => $call_params->{args}->{req_id}) : (),
            );

            if (!$res) {
                warn $client->tx->res;
                $api_response = $c->new_error($msg_type, 'WrongResponse', $c->l('Sorry, an error occurred while processing your request.'));
                $c->send({json => {%binding, %$api_response}});
                return;
            }

            $after_got_rpc_response_hook->($c, $res) if $after_got_rpc_response_hook;

            if ($res->is_error) {
                warn $res->error_message;
                $api_response = $c->new_error($msg_type, 'CallError', $c->l('Sorry, an error occurred while processing your request.'));
                $c->send({json => {%binding, %$api_response}});
                return;
            }

            $api_response = &$rpc_response_cb($res->result);

            return unless $api_response;

            if (length(JSON::to_json($api_response)) > $max_response_size) {
                $api_response = $c->new_error('error', 'ResponseTooLarge', $c->l('Response too large.'));
            }

            $api_response = {%binding, %$api_response};
            $before_send_api_response_hook->($c, $api_response) if $before_send_api_response_hook;
            $c->send({json => $api_response});
            $after_sent_api_response_hook->($c) if $after_sent_api_response_hook;

            return;
        });
    return;
}

1;

__END__

=head1 NAME

BOM::WebSocketAPI::CallingEngine

=head1 DESCRIPTION

The calling engine which does the actual RPC call.

=head1 METHODS

=head2 forward

Forward the call to RPC service and return answer to websocket connection.

Call params made in make_call_params method.
Response made in success_api_response method.
These methods would be override or extend custom functionality.

=head2 make_call_params

Make RPC call params.
If the action require auth then it'll forward token from server storage.

Method params:
    stash_params - it contains params to forward from server storage.
    call_params - callback for custom making call params.

=head2 rpc_response_cb

Callback for RPC service response.
Can use custom handlers error and success.

=head2 store_response

Save RPC response to storage.

=head2 success_api_response

Make wsapi proxy server response from RPC response.

=head2 error_api_response

Make wsapi proxy server response from RPC response.

=head2 call_rpc

Make RPC call.

=cut
