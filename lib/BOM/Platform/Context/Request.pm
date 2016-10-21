package BOM::Platform::Context::Request;

use Moose;
use Moose::Util::TypeConstraints;

use URL::Encode;

use BOM::Platform::Runtime;
use LandingCompany::Countries;

use Plack::App::CGIBin::Streaming::Request;
use LandingCompany::Registry;
use File::ShareDir;
use Sys::Hostname;

with 'BOM::Platform::Context::Request::Urls', 'BOM::Platform::Context::Request::Builders';

has 'cookies' => (
    is => 'ro',
);

has 'params' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'cgi' => (
    is => 'ro',
);

has 'mojo_request' => (
    is => 'ro',
);

has 'http_method' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'http_handler' => (
    is  => 'rw',
    isa => 'Maybe[Plack::App::CGIBin::Streaming::Request]',
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

# Is the user accessing back office page, Boolean
has 'backoffice' => (
    is  => 'ro',
    isa => 'Bool',
);

# Country of the user determined by what ever mechanism. Ex. Australia
has 'country' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'country_code' => (
    is      => 'ro',
    default => 'aq',
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

has 'available_currencies' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'default_currency' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'from_ui' => (
    is => 'ro',
);

has '_ip' => (
    is => 'ro',
);

has 'start_time' => (
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
    } elsif ($request = $self->cgi) {
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

sub _build_http_method {
    my $self = shift;

    if (my $request = $self->mojo_request) {
        return $request->method;
    } elsif ($request = $self->cgi) {
        return $request->request_method;
    }

    return "";
}

sub _build_country {
    my $self = shift;
    return LandingCompany::Countries->instance->countries->country_from_code($self->country_code);
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

my $countries_list;

BEGIN {
    $countries_list = YAML::XS::LoadFile(File::ShareDir::dist_file('LandingCompany','countries.yml'));
}

sub _build_broker_code {
    my $self = shift;

    if ($self->backoffice) {
        return $self->param('broker') if $self->param('broker');

        my $loginid = $self->param('LOGINID') || $self->param('loginID');
        if ($loginid and $loginid =~ /^([A-Z]+)\d+$/) {
            return $1;
        }

        return 'CR';
    }

    my $company = $countries_list->{$self->country_code}->{gaming_company};
    $company = $countries_list->{$self->country_code}->{financial_company} if (not $company or $company eq 'none');

    return LandingCompany::Registry::get($company)->broker_codes->[0];

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

sub _build_available_currencies {
    my $self = shift;

    return LandingCompany::Registry::get_by_broker($self->broker_code)->legal_allowed_currencies;
}

sub _build_default_currency {
    my $self = shift;

    #First try to get a country specific currency.
    my $currency = $self->_country_specific_currency($self->country_code);
    if ($currency and LandingCompany::Registry::get_by_broker($self->broker_code)->is_currency_legal($currency)) {
        if (grep { $_ eq $currency } @{$self->available_currencies}) {
            return $currency;
        }
    }

    #Next see if the default in landing company is available.
    $currency = LandingCompany::Registry::get_by_broker($self->broker_code)->legal_default_currency;
    if (grep { $_ eq $currency } @{$self->available_currencies}) {
        return $currency;
    }

    #Give the first available.
    return $self->available_currencies->[0];
}

sub _build_client_ip {
    my $self = shift;
    return ($self->_ip || '127.0.0.1');
}

sub _country_specific_currency {
    my $self    = shift;
    my $country = shift;
    $country = lc $country;

    return unless ($country);

    if    (' fr dk de at be cz fi gr ie it lu li mc nl no pl se sk  ' =~ / $country /i) { return 'EUR'; }
    elsif (' au nz cx cc nf ki nr tv ' =~ / $country /i)                                { return 'AUD'; }
    elsif (' gb uk ' =~ / $country /i)                                                  { return 'GBP'; }

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

=head1 AUTHOR

Arun Murali, C<< < arun at regentmarkets.com> >>

=head1 COPYRIGHT

(c) 2013-, RMG Tech (Malaysia) Sdn Bhd

=cut
