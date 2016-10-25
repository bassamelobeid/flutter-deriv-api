package BOM::Backoffice::Request::Base;

use Moose;
use Mojo::URL;
use Encode;
use Plack::App::CGIBin::Streaming::Request;

with 'BOM::Backoffice::Request::Role';

has 'cgi' => (is => 'ro');

has 'client_ip' => (
    is      => 'ro',
    isa     => 'Str',
    default => '127.0.0.1'
);

has 'http_handler' => (
    is  => 'rw',
    isa => 'Maybe[Plack::App::CGIBin::Streaming::Request]',
);

has 'language' => (
    is      => 'ro',
    isa     => 'Str',
    default => 'EN'
);

has 'http_method' => (
    is         => 'ro',
    lazy_build => 1
);

has 'from_ui' => (is => 'ro');

has 'backoffice' => (
    is      => 'ro',
    isa     => 'Bool',
    default => 1
);

has 'params' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'broker_code' => (
    is  => 'ro',
    isa => subtype(
        Str => where {
            my $test = $_;
            exists {map { $_ => 1 } qw(CR MLT MF MX VRTC FOG JP VRTJ)}->{$test}
        } => message {
            "Unknown broker code [$_]"
        }
    ),
    lazy_build => 1,
);

sub _build_broker_code {
    my $self = shift;

    return $self->param('broker') if $self->param('broker');

    my $loginid = $self->param('LOGINID') || $self->param('loginID');
    if ($loginid and $loginid =~ /^([A-Z]+)\d+$/) {
        return $1;
    }

    return 'CR';
}

sub _build_http_method {
    my $self = shift;

    if ($request = $self->cgi) {
        return $request->request_method;
    }

    return "";
}

sub param {
    my $self = shift;
    my $name = shift;
    return $self->params->{$name};
}

sub _build_params {
    my $self = shift;

    my $params = {};
    if (my $request = $self->cgi) {
        foreach my $param ($request->param) {
            my @p = $request->param($param);
            if (scalar @p > 1) {
                $params->{$param} = \@p;
            } else {
                $params->{$param} = shift @p;
            }
        }
        #Sometimes we also have params on post apart from the post values. Collect them as well.
        if ($self->http_method eq 'POST') {
            foreach my $param ($request->url_param) {
                my @p = $request->url_param($param);
                if (scalar @p > 1) {
                    $params->{$param} = \@p;
                } else {
                    $params->{$param} = shift @p;
                }
            }
        }
    }

    #decode all input params to utf-8
    foreach my $param (keys %{$params}) {
        if (ref $params->{$param} eq 'ARRAY') {
            my @values = @{$params->{$param}};
            $params->{$param} = [];
            foreach my $value (@values) {
                $value = Encode::decode('UTF-8', $value) unless Encode::is_utf8($value);
                push @{$params->{$param}}, $value;
            }
        } else {
            $params->{$param} = Encode::decode('UTF-8', $params->{$param}) unless Encode::is_utf8($params->{$param});
            $params->{$param} = $params->{$param};
        }
    }

    return $params;
}

sub BUILD {
    my $self = shift;
    if ($self->http_method and not grep { $_ eq $self->http_method } qw/GET POST HEAD OPTIONS/) {
        die($self->http_method . " is not an accepted request method");
    }
    return;
}

__PACKAGE__->meta->make_immutable;

1;
