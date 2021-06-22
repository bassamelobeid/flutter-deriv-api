package BOM::Test::App::RPC;

use strict;
use warnings;

use Role::Tiny;
use BOM::RPC::Transport::Redis;
use BOM::Test::RPC::QueueClient;

sub build_test_app {
    my ($self, $args) = @_;

    my $redis_cfg = BOM::Config::Redis::redis_config('rpc', 'write');
    my $consumer  = BOM::RPC::Transport::Redis->new(
        worker_index => 1,
        redis_uri    => $redis_cfg->{uri},
    );

    local $SIG{HUP} = sub {
        $consumer->stop;
        exit;
    };

    return $consumer;
}

sub test_schema {
    my ($self, $req_params, $expected_json_schema, $descr, $should_be_failed) = @_;

    my $c      = BOM::Test::RPC::QueueClient->new();
    my $result = $c->call_ok(@$req_params)->result;

    return $self->_test_schema($result, $expected_json_schema, $descr, $should_be_failed);
}

sub adjust_req_params {
    my ($self, $params) = @_;
    my $adjusted_params = [$self->{call}, $params];
    $adjusted_params->[1]->{language} = $self->{language} if $self->{language};
    return $adjusted_params;
}

1;
