package BOM::WebSocketAPI::v3::RPC;

use strict;
use warnings;
use MojoX::JSON::RPC::Client;
use Time::HiRes;

sub rpc {
    my $self     = shift;
    my $method   = shift;
    my $callback = shift;
    my $params   = shift;

    my $tv = [Time::HiRes::gettimeofday];
    state $cpu = Proc::CPUUsage->new();

    $params->{language} = $self->stash('language');

    my $client = MojoX::JSON::RPC::Client->new;
    my $url    = 'http://127.0.0.1:5005/' . $method;

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
            if (!$res) {
                my $tx_res = $client->tx->res;
                warn $tx_res->message;
                my $data = $self->new_error('error', 'WrongResponse', $self->l('Wrong response.'));
                $data->{echo_req} = $params->{args};
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
                my $data = $self->new_error('error', 'CallError', $self->l('Call error.' . $res->error_message));
                $data->{echo_req} = $params->{args};
                $self->send({json => $data});
                return;
            }
            my $send = 1;

            my $data = &$callback($res->result);

            if (not $data) {
                $send = undef;
                $data = {};
            }

            my $args = $params->{args};
            $data->{echo_req} = $args;
            $data->{req_id} = $args->{req_id} if ($args and exists $args->{req_id});

            my $l = length JSON::to_json($data);
            if ($l > 328000) {
                $data = $self->new_error('error', 'ResponseTooLarge', $self->l('Response too large.'));
                $data->{echo_req} = $args;
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
        });
    return;
}
