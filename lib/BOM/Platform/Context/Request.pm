package BOM::Platform::Context::Request;

use Moose;
use Moose::Util::TypeConstraints;

use URL::Encode;

use BOM::Platform::Runtime;
use BOM::Platform::Countries;

use Plack::App::CGIBin::Streaming::Request;
use BOM::Platform::LandingCompany::Registry;
use Sys::Hostname;

with 'BOM::Platform::Context::Request::Builders';

has 'cookies' => (
    is => 'ro',
);

has 'mojo_request' => (
    is => 'ro',
);

has 'http_method' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'domain_name' => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has 'client_ip' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'country_code' => (
    is      => 'ro',
    default => 'aq',
);

has 'language' => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has cookie_domain => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_cookie_domain'
);

has '_ip' => (
    is => 'ro',
);

sub cookie {
    my $self = shift;
    my $name = shift;

    if ($self->mojo_request) {
        my $cookie = $self->mojo_request->cookie($name);
        if ($cookie) {
            return URL::Encode::url_decode($cookie->value);
        }
    }

    if ($self->cookies) {
        return $self->cookies->{$name};
    }

    return;
}

sub _build_http_method {
    my $self = shift;

    if (my $request = $self->mojo_request) {
        return $request->method;
    }

    return "";
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

    my @host_name = split(/\./, Sys::Hostname::hostname);
    my $name = $host_name[0];

    if ($name =~ /^qa\d+$/) {
        return 'binary' . $name . '.com';
    }
    return 'binary.com';
}

sub _build_language {
    my $self = shift;

    return 'EN' if $self->backoffice;

    my $language;
    if ($self->param('l')) {
        $language = $self->param('l');
    } elsif ($self->cookie('language')) {
        $language = $self->cookie('language');
    }

    # while we have url ?l=EN and POST with l=EN, it goes to ARRAY
    $language = $language->[0] if ref($language) eq 'ARRAY';

    if ($language and grep { $_ eq uc $language } @{BOM::Platform::Runtime->instance->app_config->cgi->allowed_languages}) {
        return uc $language;
    }

    return 'EN';
}

sub _build_client_ip {
    my $self = shift;
    return ($self->_ip || '127.0.0.1');
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
