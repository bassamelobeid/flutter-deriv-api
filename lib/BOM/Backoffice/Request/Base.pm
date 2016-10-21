package BOM::Backoffice::Request::Base;

use Moose;
use Mojo::URL;
use Plack::App::CGIBin::Streaming::Request;

with 'BOM::Backoffice::Request::Role';

has 'http_handler' => (
    is  => 'rw',
    isa => 'Maybe[Plack::App::CGIBin::Streaming::Request]',
);

has 'client_ip' => (
    is      => 'ro',
    isa     => 'Str',
    default => '127.0.0.1'
);

has 'http_method' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'language' => (
    is      => 'ro',
    isa     => 'Str',
    default => 'EN',
);

sub BUILD {
    my $self = shift;
    if ($self->http_method and not grep { $_ eq $self->http_method } qw/GET POST HEAD OPTIONS/) {
        die($self->http_method . " is not an accepted request method");
    }
    return;
}

__PACKAGE__->meta->make_immutable;

1;
