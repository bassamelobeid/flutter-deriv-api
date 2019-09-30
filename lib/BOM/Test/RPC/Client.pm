package BOM::Test::RPC::Client;

use Data::Dumper;
use MojoX::JSON::RPC::Client;
use Test::More qw();
use Data::UUID;
use Job::Async::Client::Redis;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use MojoX::JSON::RPC::Client;

use BOM::Test::WebsocketAPI::Redis::RpcQueue;

use Moose;
use namespace::autoclean;

has 'ua' => (
    is       => 'ro',
    required => 0,
);
has 'redis' => (
    is       => 'ro',
    required => 0,
);
has 'loop' => (
    is       => 'ro',
    required => 1,
    builder  => '_build_loop',
);
has 'client' => (
    is         => 'ro',
    builder    => '_build_client',
    lazy_build => 1,
);
has 'response' => (is => 'rw');
has 'result'   => (is => 'rw');
has 'params'   => (
    is  => 'rw',
    isa => 'ArrayRef'
);

sub _build_loop {
    return IO::Async::Loop::Mojo->new;
}

sub _build_client {
    my $self = shift;
    return MojoX::JSON::RPC::Client->new(ua => $self->ua) if $self->ua;
    if ($self->redis) {
        my $queue_redis  = BOM::Test::WebsocketAPI::Redis::RpcQueue->new->config->{write};
        my $queue_prefix = $ENV{JOB_QUEUE_PREFIX};
        $self->loop->add(
            my $client = Job::Async::Client::Redis->new(
                uri     => 'redis://' . $queue_redis->{host} . ':' . $queue_redis->{port},
                timeout => 5,
                $queue_prefix ? (prefix => $queue_prefix) : (),
            ));
        $client->start->get;
        return $client;
    }

    die 'Unknown rpc client type (neither http nor queue)';
}

sub call_ok {
    my ($self, $method, $req_params, $description) = @_;

    $description ||= "called /$method";

    $req_params->{source} //= 1;

    $self->_tcall($method, $req_params);

    $self->_test('ok', $self->response, $description);
    return $self;
}

sub has_no_system_error {
    my ($self, $description) = @_;
    my $method = $self->params->[0];
    $description ||= "response for /$method has no system error";

    $self->_test('ok', !$self->response->is_error, $description);
    return $self;
}

sub has_system_error {
    my ($self, $description) = @_;
    my $method = $self->params->[0];
    $description ||= "response for /$method has system error";

    $self->_test('ok', $self->response->is_error, $description);
    return $self;
}

sub has_no_error {
    my ($self, $description) = @_;
    my $method = $self->params->[0];
    $description ||= "response for /$method has no error";

    my $result = $self->result;
    return $self unless $self->_test('ok', $result, "response for /$method has result");
    # Most RPCs return a HASH ref with an 'error' key on failure.
    # A few RPCs (e.g. mt5_password_check) return a boolean truth on success,
    # others return ARRAY refs on success.
    my $failed = ref($result) eq 'HASH' && $result->{error};
    $self->_test('ok', !$failed, $description)
        or Test::More::diag("Expected no error, got\n", Data::Dumper->Dump([$result], [qw(result)]));
    return $self;
}

sub has_error {
    my ($self, $description) = @_;
    my $method = $self->params->[0];
    $description ||= "response for /$method has error";

    my $result = $self->result;
    $self->_test('ok', $result && $result->{error}, $description);
    return $self;
}

sub error_code_is {
    my ($self, $expected, $description) = @_;
    my $result = $self->result    || {};
    my $error  = $result->{error} || {};
    $self->_test('is', $error->{code}, $expected, $description);
    return $self;
}

sub error_message_is {
    my ($self, $expected, $description) = @_;
    my $result = $self->result    || {};
    my $error  = $result->{error} || {};
    $self->_test('is', $error->{message_to_client}, $expected, $description);
    return $self;
}

sub error_internal_message_like {
    my ($self, $expected, $description) = @_;
    my $result = $self->result    || {};
    my $error  = $result->{error} || {};
    $self->_test('like', $error->{message}, $expected, $description);
    return $self;
}

sub error_message_like {
    my ($self, $expected, $description) = @_;
    my $result = $self->result    || {};
    my $error  = $result->{error} || {};
    $self->_test('like', $error->{message_to_client}, $expected, $description);
    return $self;
}

sub error_details_is {
    my ($self, $expected, $description) = @_;
    my $result = $self->result    || {};
    my $error  = $result->{error} || {};

    $self->_test('is_deeply', $error->{details}, $expected, $description);
    return $self;
}

sub result_is_deeply {
    my ($self, $expected, $description) = @_;

    $self->_test('is_deeply', $self->result, $expected, $description);
    return $self;
}

sub result_value_is {
    my ($self, $get_compared_hash_value, $expected, $description) = @_;

    $self->_test('is', $get_compared_hash_value->($self->result), $expected, $description);
    return $self;
}

sub _tcall {
    my ($self, $method, $req_params) = @_;

    $self->params([$method, $req_params]);

    my $request = {
        id     => Data::UUID->new()->create_str(),
        method => $method,
        params => $req_params
    };

    my $r;
    if (ref($self->client) eq 'MojoX::JSON::RPC::Client') {
        $r = $self->client->call(
            "/$method",
            {
                id     => Data::UUID->new()->create_str(),
                method => $method,
                params => $req_params
            });
    } else {
        $req_params->{args}->{$method} //= 1;
        my $request = {
            name   => $method,
            params => encode_json_utf8($req_params),
        };
        my $result = Future->wait_any($self->client->submit(%$request), $self->loop->delay_future(after => 10))->get;
        $r = MojoX::JSON::RPC::Client::ReturnObject->new(rpc_response => decode_json_utf8($result)) if ($result);
    }

    $self->response($r);
    $self->result($r->result) if $r;
}

sub _test {
    my ($self, $name, @args) = @_;

    my $test_level = $Test::Builder::Level;
    local $Test::Builder::Level = $test_level + 3;
    return Test::More->can($name)->(@args);
}

__PACKAGE__->meta->make_immutable;
1;
