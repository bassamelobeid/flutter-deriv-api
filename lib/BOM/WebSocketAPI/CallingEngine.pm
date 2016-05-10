package BOM::WebSocketAPI::CallingEngine;

use strict;
use warnings;

use MojoX::JSON::RPC::Client;
use Guard;
use JSON;

# TODO Move to callbacks
use BOM::System::Config;
use Time::HiRes;
use Proc::CPUUsage;
use feature 'state';
use DataDog::DogStatsd::Helper;
use Data::UUID;
# /TODO Move to callbacks

sub forward {
    my ($c, $rpc_method, $args, $params) = @_;

    $params->{msg_type} ||= $rpc_method;

    return call_rpc($c, $rpc_method, rpc_reponse_cb($c, $args, $params), make_call_params($c, $args, $params));
}

sub make_call_params {
    my ($c, $args, $params) = @_;

    my $stash_params   = $params->{stash_params};
    my $call_params_cb = $params->{call_params};
    my $require_auth   = $params->{require_auth};

    my $call_params = {
        args     => $args,
        language => $c->stash('language'),
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

sub rpc_reponse_cb {
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
    my $self        = shift;
    my $method      = shift;
    my $callback    = shift;
    my $params      = shift;
    my $method_name = shift // $method;

    my $tv = [Time::HiRes::gettimeofday];
    state $cpu = Proc::CPUUsage->new();

    $params->{language} = $self->stash('language');
    $params->{country} = $self->stash('country') || $self->country_code;

    my $client = MojoX::JSON::RPC::Client->new;
    my $url = $ENV{RPC_URL} || 'http://127.0.0.1:5005/';
    if (BOM::System::Config::env eq 'production') {
        if (BOM::System::Config::node->{node}->{www2}) {
            $url = 'http://internal-rpc-www2-703689754.us-east-1.elb.amazonaws.com:5005/';
        } else {
            $url = 'http://internal-rpc-1484966228.us-east-1.elb.amazonaws.com:5005/';
        }
    }

    $url .= $method;

    my $callobj = {
        id     => Data::UUID->new()->create_str(),
        method => $method,
        params => $params
    };

    $client->call(
        $url, $callobj,
        sub {
            my $res = pop;

            DataDog::DogStatsd::Helper::stats_timing(
                'bom_websocket_api.v_3.rpc.call.timing',
                1000 * Time::HiRes::tv_interval($tv),
                {tags => ["rpc:$method"]});
            DataDog::DogStatsd::Helper::stats_timing('bom_websocket_api.v_3.cpuusage', $cpu->usage(), {tags => ["rpc:$method"]});
            DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.rpc.call.count', {tags => ["rpc:$method"]});

            # unconditionally stop any further processing if client is already disconnected
            return unless $self->tx;

            my $client_guard = guard { undef $client };

            my ($data, $req_id);
            my $args = $params->{args};
            $req_id = $args->{req_id} if ($args and exists $args->{req_id});

            if (!$res) {
                my $tx_res = $client->tx->res;
                warn $tx_res->message;
                $data = $self->new_error($method, 'WrongResponse', $self->l('Sorry, an error occurred while processing your request.'));
                $data->{echo_req} = $args;
                $data->{req_id} = $req_id if $req_id;
                $self->send({json => $data});
                return;
            }

            my $rpc_time;
            $rpc_time = delete $res->result->{rpc_time} if (ref($res->result) eq "HASH");

            if ($rpc_time) {
                DataDog::DogStatsd::Helper::stats_timing(
                    'bom_websocket_api.v_3.rpc.call.timing.connection',
                    1000 * Time::HiRes::tv_interval($tv) - $rpc_time,
                    {tags => ["rpc:$method"]});
            }

            if ($res->is_error) {
                warn $res->error_message;
                $data = $self->new_error($method_name, 'CallError', $self->l('Sorry, an error occurred while processing your request.'));
                $data->{echo_req} = $args;
                $data->{req_id} = $req_id if $req_id;
                $self->send({json => $data});
                return;
            }

            $data = &$callback($res->result);

            _process_result($self, $data, $method, $args, $req_id, $tv);
            return;
        });
    return;
}

sub _process_result {
    my ($self, $data, $method, $args, $req_id, $tv) = @_;

    my $send = 1;
    if (not $data) {
        $send = undef;
        $data = {};
    }
    my $l = length JSON::to_json($data);
    if ($l > 328000) {
        $data = $self->new_error('error', 'ResponseTooLarge', $self->l('Response too large.'));
    }

    $data->{echo_req} = $args;
    $data->{req_id} = $req_id if $req_id;

    if ($self->stash('debug')) {
        $data->{debug} = {
            time   => 1000 * Time::HiRes::tv_interval($tv),
            method => $method
        };
    }

    if ($send) {
        $tv = [Time::HiRes::gettimeofday];

        $self->send({json => $data});

        DataDog::DogStatsd::Helper::stats_timing(
            'bom_websocket_api.v_3.rpc.call.timing.sent',
            1000 * Time::HiRes::tv_interval($tv),
            {tags => ["rpc:$method"]});

    }
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

=head2 rpc_reponse_cb

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
