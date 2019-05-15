package BOM::Platform::Context::Request;

use Moose;
use Encode;
use URL::Encode;
use Sys::Hostname;

use BOM::Config::Runtime;

with 'BOM::Platform::Context::Request::Builders';

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

has 'params' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'brand' => (
    is         => 'ro',
    lazy_build => 1,
);

has '_ip' => (
    is => 'ro',
);

sub param {
    my $self = shift;
    my $name = shift;
    return $self->params->{$name};
}

sub _build_params {
    my $self = shift;

    my $params = {};
    if (my $request = $self->mojo_request) {
        $params = $request->params->to_hash;
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

sub _build_http_method {
    my $self = shift;

    if (my $request = $self->mojo_request) {
        return $request->method;
    }

    return "";
}

sub _build_domain_name {
    my $self = shift;

    my @host_name = split(/\./, Sys::Hostname::hostname);
    my $name = $host_name[0];

    if ($name =~ /^qa\d+$/) {
        return 'www.binary' . $name . '.com';
    }
    return 'www.binary.com';
}

sub _build_language {
    my $self = shift;

    my $language;
    if ($self->param('l')) {
        $language = $self->param('l');
    }

    # while we have url ?l=EN and POST with l=EN, it goes to ARRAY
    $language = $language->[0] if ref($language) eq 'ARRAY';

    if ($language and grep { $_ eq uc $language } @{BOM::Config::Runtime->instance->app_config->cgi->allowed_languages}) {
        return uc $language;
    }

    return 'EN';
}

sub _build_client_ip {
    my $self = shift;
    return ($self->_ip || '127.0.0.1');
}

sub _build_brand {
    my $self = shift;

    if (my $brand = $self->param('brand')) {
        return $brand;
    } elsif (my $domain = $self->domain_name) {
        # webtrader.champion-fx.com -> champion, visit this regex
        # when we add new brand
        ($domain) = ($domain =~ /\.([a-z]+).*?\./);
        # for qa return binary
        return ($domain =~ /^binaryqa/ ? 'binary' : $domain);
    }

    return "binary";
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
