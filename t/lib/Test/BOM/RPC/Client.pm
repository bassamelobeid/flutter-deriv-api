package Test::BOM::RPC::Client;

use Moose;

use Data::Dumper;
use Test::More;
use MojoX::JSON::RPC::Client;

has 'ua'     => ( is => 'ro' );
has 'client' => (
    is => 'ro',
    isa => 'MojoX::JSON::RPC::Client',
    builder => '_build_client',
    lazy_build => 1,
);
has 'response' => ( is => 'rw' );
has 'params' => ( is => 'rw', isa => 'ArrayRef' );

sub _build_client {
    my $self = shift;
    return MojoX::JSON::RPC::Client->new( ua => $self->ua );
}

sub call_ok {
    my $self = shift;
    my ( $method ) = @_;

    $self->_tcall(@_);

    ok( $self->response, "called /$method" );
    return $self;
}

sub has_no_system_error {
    my $self   = shift;
    my $method = $self->params->[0];

    ok( ! $self->response->is_error, "response for /$method has no system error" );
    return $self;
}

sub has_system_error {
    my $self   = shift;
    my $method = $self->params->[0];

    ok( $self->response->is_error, "response for /$method has system error" );
    return $self;
}

sub has_no_error {
    my $self   = shift;
    my $method = $self->params->[0];

    my $result = $self->response->{result} || {};
    ok( ! $result->{error}, "response for /$method has no error" );
    return $self;
}

sub has_error {
    my $self   = shift;
    my $method = $self->params->[0];

    my $result = $self->response->{result} || {};
    ok( $result->{error}, "response for /$method has error" );
    return $self;
}

sub error_code_is {
    my ( $self, $expected, $description ) = @_;
    my $result = $self->response->{result} || {};
    is( $result->{error}->{code}, $expected, $description );
    return $self;
}

sub error_message_is {
    my ( $self, $expected, $description ) = @_;
    my $result = $self->response->{result} || {};
    is( $result->{error}->{message_to_client}, $expected, $description );
    return $self;
}

sub result_is_deeply {
    my ( $self, $expected, $description ) = @_;

    is_deeply( $self->response->result, $expected, $description );
    return $self;
}

sub result_value_is {
    my ( $self, $get_compared_hash_value, $expected, $description ) = @_;

    is( $get_compared_hash_value->( $self->response->result ), $expected, $description );
    return $self;
}

sub _tcall {
    my ( $self, $method, $req_params ) = @_;

    $self->params([ $method, $req_params ]);

    my $r = $self->client->call(
        "/$method",
        {
            id     => Data::UUID->new()->create_str(),
            method => $method,
            params => $req_params
        }
    );

    $self->response($r);

    return $r;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
