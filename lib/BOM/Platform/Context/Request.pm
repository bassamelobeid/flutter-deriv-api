package BOM::Platform::Context::Request;

use Moose;
use Encode;
use URL::Encode;
use Sys::Hostname;

use Brands;
use BOM::Config::Runtime;
use BOM::Database::Model::OAuth;

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

has 'brand_name' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'app_id' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'app' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'source' => (is => 'ro');

has '_ip' => (
    is => 'ro',
);

sub param {
    my $self = shift;
    my $name = shift;
    return $self->params->{$name};
}

sub brand {
    my $self = shift;
    return Brands->new(name => $self->brand_name);
}

=head2 login_env

Get the environment of the current user.
It can be called with an optional HASH ref containing the following parameters to overwrite the values:

=over

=item * C<client_ip> - Optional.

=item * C<country_code> - Optional.

=item * C<language> - Optional.

=item * C<user_agent> - Optional.

=back

=cut

sub login_env {
    my ($self, $params) = @_;

    my $now = Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ;

    my $ip_address = $params->{client_ip} || $self->client_ip || '';
    my $ip_address_country = uc($params->{country_code} || $self->country_code || '');
    my $lang               = uc($params->{language}     || $self->language     || '');

    ## The User-Agent can be arbitrarily large, but we do not want to store anything
    ## too large in the database, so we truncate it here if the final environment
    ## string goes over 1000 characters

    my $max_env_length    = 1000;
    my $ua                = $params->{user_agent} || '';
    my $ua_string_length  = length($ua);
    my $env_string_length = length("$now IP=$ip_address IP_COUNTRY=$ip_address_country User_AGENT= LANG=$lang");
    my $total_env_length  = $env_string_length + $ua_string_length;
    if ($total_env_length > $max_env_length) {
        my $ua_note     = " AGENT_TRUNCATED=$ua_string_length";
        my $new_ua_size = $max_env_length - $env_string_length - length($ua_note);
        $ua = substr($ua, 0, $new_ua_size);
        $ua .= $ua_note;
    }

    return "$now IP=$ip_address IP_COUNTRY=$ip_address_country User_AGENT=$ua LANG=$lang";

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

sub _build_brand_name {
    my $self = shift;

    if (my $brand = $self->param('brand')) {
        return $brand->[0] if (ref($brand) eq 'ARRAY');
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

sub _build_app_id {
    my $self = shift;
    return ($self->param('app_id') || $self->source || '');
}

sub _build_app {
    my $self = shift;

    return undef unless $self->app_id;
    return BOM::Database::Model::OAuth->new->get_app_by_id($self->app_id);
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
