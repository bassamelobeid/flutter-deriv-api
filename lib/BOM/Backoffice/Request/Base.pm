package BOM::Backoffice::Request::Base;

use Moose;
use Moose::Util::TypeConstraints;
use Mojo::URL;
use Encode;
use Sys::Hostname;
use Plack::App::CGIBin::Streaming::Request;

use LandingCompany::Registry;

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
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1
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

has 'cookies' => (
    is => 'ro',
);

has cookie_domain => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_cookie_domain'
);

has 'domain_name' => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has 'brand' => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

{
    my %known_codes = map { ; $_ => 1 } qw(CR MLT MF MX VRTC FOG CH VRCH);
    has 'broker_code' => (
        is  => 'ro',
        isa => subtype(
            Str => where {
                exists $known_codes{$_};
            } => message {
                "Unknown broker code [$_]";
            }
        ),
        lazy_build => 1,
    );
}

has 'available_currencies' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_language {
    my $self = shift;

    return $self->param('l') // 'EN';
}

sub _build_broker_code {
    my $self = shift;

    return $self->param('broker') if $self->param('broker');

    my $loginid = $self->param('LOGINID') || $self->param('loginID');
    if ($loginid and $loginid =~ /^([A-Z]+)\d+$/) {
        return $1;
    }

    return 'CR';
}

sub _build_brand {
    my $self = shift;

    my $broker = $self->broker_code // '';
    if ($broker =~ /^(?:CH|VRCH)/) {
        return 'champion';
    }

    return 'binary';
}

sub _build_available_currencies {
    my $self = shift;

    my $landing_company = LandingCompany::Registry->get_by_broker($self->broker_code);
    unless ($landing_company) {
        my $err = sprintf "Invalid landing company for broker code [%s]", $self->broker_code;
        print $err;
        die $err;
    }
    return [keys %{$landing_company->legal_allowed_currencies}];
}

sub _build_http_method {
    my $self = shift;

    if (my $request = $self->cgi) {
        return $request->request_method;
    }

    return "";
}

sub _build_params {
    my $self = shift;

    my $params = {};
    if (my $request = $self->cgi) {
        foreach my $param ($request->param) {
            my @p = $request->multi_param($param);
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
                $value = Encode::decode('UTF-8', $value);
                push @{$params->{$param}}, $value;
            }
        } else {
            $params->{$param} = Encode::decode('UTF-8', $params->{$param});
        }
    }

    return $params;
}

sub _build_cookie_domain {
    my $self   = shift;
    my $domain = $self->domain_name;
    return $domain if $domain eq '127.0.0.1';
    $domain =~ s/^[^.]+\.([^.]+\..+)/$1/;
    return "." . $domain;
}

sub _build_domain_name {
    my $self = shift;

    my @host_name = split(/\./, Sys::Hostname::hostname());
    my $name = $host_name[0];

    if ($name =~ /^qa\d+$/) {
        return 'binary' . $name . '.com' if $host_name[1] eq 'regentmarkets';
        return Sys::Hostname::hostname();
    }
    return 'binary.com';
}

sub param {
    my $self = shift;
    my $name = shift;
    return $self->params->{$name};
}

sub checkbox_param {
    my $self = shift;
    my $name = shift;
    return $self->params->{$name} // 0;
}

sub cookie {
    my $self = shift;
    my $name = shift;

    if ($self->cookies) {
        return $self->cookies->{$name};
    }

    return;
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
