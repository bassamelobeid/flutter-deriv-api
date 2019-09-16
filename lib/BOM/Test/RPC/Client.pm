package BOM::Test::RPC::Client;

use Data::Dumper;
use MojoX::JSON::RPC::Client;
use Test::More qw();
use Data::UUID;

use Moose;
use namespace::autoclean;

has 'ua' => (
    is       => 'ro',
    required => 1,
);
has 'client' => (
    is         => 'ro',
    isa        => 'MojoX::JSON::RPC::Client',
    builder    => '_build_client',
    lazy_build => 1,
);
has 'response' => (is => 'rw');
has 'result'   => (is => 'rw');
has 'params'   => (
    is  => 'rw',
    isa => 'ArrayRef'
);

sub _build_client {
    my $self = shift;
    return MojoX::JSON::RPC::Client->new(ua => $self->ua);
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

    my $r = $self->client->call(
        "/$method",
        {
            id     => Data::UUID->new()->create_str(),
            method => $method,
            params => $req_params
        });

    $self->response($r);
    $self->result($r->result) if $r;

    return $r;
}

sub _test {
    my ($self, $name, @args) = @_;

    my $test_level = $Test::Builder::Level;
    local $Test::Builder::Level = $test_level + 3;
    return Test::More->can($name)->(@args);
}

__PACKAGE__->meta->make_immutable;
1;
