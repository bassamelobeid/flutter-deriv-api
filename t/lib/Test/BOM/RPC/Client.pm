package Test::BOM::RPC::Client;

use Data::Dumper;
use MojoX::JSON::RPC::Client;
use Test::Builder;
use Test::More ();

use Moose;
use namespace::autoclean;

has 'ua'     => (is => 'ro');
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
has tb => (
    is => 'ro',
    builder => '_build_tb',
);

sub _build_tb {
    return Test::Builder->new;
}

sub _build_client {
    my $self = shift;
    return MojoX::JSON::RPC::Client->new(ua => $self->ua);
}

sub call_ok {
    my $self = shift;
    my ($method, $req_params, $description) = @_;

    $description ||= "called /$method";

    $self->_tcall(@_);

    $self->tb->ok($self->response, $description);
    return $self;
}

sub has_no_system_error {
    my ( $self, $description ) = @_;
    my $method = $self->params->[0];
    $description ||= "response for /$method has no system error";

    $self->tb->ok(!$self->response->is_error, $description);
    return $self;
}

sub has_system_error {
    my ( $self, $description ) = @_;
    my $method = $self->params->[0];
    $description ||= "response for /$method has system error";

    $self->tb->ok($self->response->is_error, $description);
    return $self;
}

sub has_no_error {
    my ( $self, $description ) = @_;
    my $method = $self->params->[0];
    $description ||= "response for /$method has no error";

    my $result = $self->result;
    $self->tb->ok( $result && !$result->{error}, $description);
    return $self;
}

sub has_error {
    my ( $self, $description ) = @_;
    my $method = $self->params->[0];
    $description ||= "response for /$method has error";

    my $result = $self->result;
    $self->tb->ok( $result && $result->{error}, $description);
    return $self;
}

sub error_code_is {
    my ($self, $expected, $description) = @_;
    my $result = $self->result || {};
    $self->tb->is($result->{error}->{code}, $expected, $description);
    return $self;
}

sub error_message_is {
    my ($self, $expected, $description) = @_;
    my $result = $self->result || {};
    $self->tb->is($result->{error}->{message_to_client}, $expected, $description);
    return $self;
}

sub result_is_deeply {
    my ($self, $expected, $description) = @_;

    $Test::Builder::Level += 1;
    Test::More::is_deeply($self->result, $expected, $description);
    return $self;
}

sub result_value_is {
    my ($self, $get_compared_hash_value, $expected, $description) = @_;

    $self->tb->is($get_compared_hash_value->($self->result), $expected, $description);
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

__PACKAGE__->meta->make_immutable;
1;
