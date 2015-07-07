package BOM::Platform::Context::Request;

use Moose;

use JSON;
use CGI;
use CGI::IDS;
use CGI::Untaint;
use URL::Encode;
use Data::Dumper;
use Try::Tiny;

use BOM::Platform::Runtime;
use BOM::Platform::Runtime::Website;
use BOM::Platform::Auth0;
use BOM::Platform::SessionCookie;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Utility::Untaint;

use Plack::App::CGIBin::Streaming::Request;

use BOM::System::Types;

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

has 'http_path' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'http_handler' => (
    is  => 'rw',
    isa => 'Maybe[Plack::App::CGIBin::Streaming::Request]',
);

has 'untainter' => (
    is         => 'ro',
    lazy_build => 1
);

has 'is_pjax' => (
    is         => 'ro',
    lazy_build => 1
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
    is         => 'ro',
    lazy_build => 1,
);

has 'loginid' => (
    is         => 'ro',
    isa        => 'Maybe[Str]',
    lazy_build => 1,
);

has 'email' => (
    is         => 'ro',
    isa        => 'Maybe[Str]',
    lazy_build => 1,
);

has 'session_cookie' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'bo_cookie' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'ui_settings' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'broker_code' => (
    is         => 'ro',
    isa        => 'bom_broker_code',
    lazy_build => 1,
);

has 'language' => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has 'website' => (
    is         => 'ro',
    isa        => 'BOM::Platform::Runtime::Website',
    lazy_build => 1,
);

has 'broker' => (
    is         => 'ro',
    isa        => 'BOM::Platform::Runtime::Broker',
    lazy_build => 1,
);

has cookie_domain => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_cookie_domain'
);

has 'real_account_broker' => (
    is         => 'ro',
    isa        => 'BOM::Platform::Runtime::Broker',
    lazy_build => 1,
);

has 'virtual_account_broker' => (
    is         => 'ro',
    isa        => 'BOM::Platform::Runtime::Broker',
    lazy_build => 1,
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

has 'http_modified' => (
    is => 'ro',
);

sub currency_available {
    my $self     = shift;
    my $currency = shift;

    return unless $currency;
    return grep { $currency eq $_ } @{$self->available_currencies};
}

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

sub param_untaint {
    my $self = shift;
    return $self->untainter->extract(@_);
}

sub ui_settings_value {
    my $self = shift;
    if (scalar keys %{$self->ui_settings}) {
        return to_json($self->ui_settings);
    }

    return '';
}

sub is_logged_into_bo {
    my $self = shift;

    my $cookie = $self->bo_cookie;
    if ($cookie and $cookie->clerk) {
        if (BOM::Platform::Auth0::from_cookie($cookie) or BOM::Platform::Auth0::login($cookie->token)) {
            return 1;
        }
    }
    return;
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
        }
    }

    return $params;
}

sub _build_untainter {
    my $self = shift;
    return CGI::Untaint->new({INCLUDE_PATH => 'BOM::Utility::Untaint'}, %{$self->params});
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

sub _build_http_path {
    my $self = shift;

    if (my $request = $self->mojo_request) {
        return $request->url->path;
    } elsif ($request = $self->cgi) {
        return $request->script_name;
    }

    return "UNKNOWN";
}

sub _build_is_pjax {
    my $self = shift;
    if (exists $self->params->{_pjax}) {
        return 1;
    }

    return;
}

sub _build_country {
    my $self = shift;
    return BOM::Platform::Runtime->instance->countries->country_from_code($self->country_code);
}

sub _build_country_code {
    my $self = shift;

    my $ip = $self->client_ip;
    if (($ip =~ /^99\.99\.99\./) or ($ip =~ /^192\.168\./) or ($ip eq '127.0.0.1')) {
        return 'aq';
    }

    return;
}

sub _build_cookie_domain {
    my $self   = shift;
    my $domain = $self->domain_name;
    $domain =~ s/^[^.]+\.([^.]+\..+)/$1/;
    return "." . $domain;
}

sub _build_domain_name {
    my $self = shift;
    return BOM::Platform::Runtime->instance->hosts->localhost->external_fqdn;
}

sub _build_broker_code {
    my $self = shift;

    if ($self->backoffice) {
        my $input_broker = $self->param('broker') || $self->param('w');
        if ($input_broker and BOM::Platform::Runtime->instance->broker_codes->get($input_broker)->code) {
            return $input_broker;
        }

        my $loginid = $self->param('LOGINID') || $self->param('loginID');
        if ($loginid and BOM::Platform::Runtime->instance->broker_codes->get($loginid)->code) {
            return BOM::Platform::Runtime->instance->broker_codes->get($loginid)->code;
        }
    }

    if (my $input_broker = $self->param('broker')) {
        return BOM::Platform::Runtime->instance->broker_codes->get($input_broker)->code;
    }

    if ($self->loginid and BOM::Platform::Runtime->instance->broker_codes->get($self->loginid)->code) {
        return BOM::Platform::Runtime->instance->broker_codes->get($self->loginid)->code;
    }

    return $self->real_account_broker->code;
}

sub _build_broker {
    my $self = shift;
    return BOM::Platform::Runtime->instance->broker_codes->get($self->broker_code);
}

sub _build_virtual_account_broker {
    my $self = shift;
    return unless ($self->website);
    return $self->website->broker_for_new_virtual($self->country);
}

sub _build_real_account_broker {
    my $self = shift;
    return unless ($self->website);
    return $self->website->broker_for_new_account($self->country);
}

sub _build_language {
    my $self = shift;

    my $language = $self->param('l');
    # while we have url ?l=EN and POST with l=EN, it goes to ARRAY
    $language = $language->[0] if ref($language) eq 'ARRAY';

    if ($language and grep { $_ eq uc $language } @{BOM::Platform::Runtime->instance->app_config->cgi->allowed_languages}) {
        return uc $language;
    }

    if ($self->website) {
        return $self->website->default_language;
    }

    return 'EN';
}

sub _build_website {
    my $self = shift;

    my $parameters = {};
    $parameters->{domain_name} = $self->domain_name;
    $parameters->{backoffice} = 1 if ($self->backoffice);
    return BOM::Platform::Runtime->instance->website_list->choose_website($parameters);
}

sub _build_available_currencies {
    my $self      = shift;
    my $available = $self->broker->landing_company->legal_allowed_currencies;

    if (scalar @{$self->website->filtered_currencies} > 0) {
        $available = [grep { $self->broker->landing_company->is_currency_legal($_) } @{$self->website->filtered_currencies}];
    }

    return $available;
}

sub _build_default_currency {
    my $self = shift;

    #First try to get a country specific currency.
    my $currency = $self->_country_specific_currency($self->country_code);
    if ($currency and $self->broker->landing_company->is_currency_legal($currency)) {
        if (grep { $_ eq $currency } @{$self->available_currencies}) {
            return $currency;
        }
    }

    #Next see if the default in landing company is available.
    $currency = $self->broker->landing_company->legal_default_currency;
    if (grep { $_ eq $currency } @{$self->available_currencies}) {
        return $currency;
    }

    #Give the first available.
    return $self->available_currencies->[0];
}

sub _build_loginid {
    my $self = shift;

    if ($self->session_cookie) {
        return $self->session_cookie->loginid;
    }

    # not logged in
    return;
}

sub _build_email {
    my $self = shift;

    if ($self->session_cookie) {
        return $self->session_cookie->email;
    }

    # not logged in
    return;
}

sub _build_session_cookie {
    my $self = shift;

    my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;

    my $session_cookie;
    # if the user logged in.
    if (my $cookie = $self->cookie($cookie_name)) {
        $session_cookie = BOM::Platform::SessionCookie->from_value($cookie);
    } elsif (my $as_param = $self->param('login')) {
        $session_cookie = BOM::Platform::SessionCookie->from_value($as_param);
    }

    if (    $session_cookie
        and BOM::Platform::Runtime->instance->broker_codes->get($session_cookie->loginid)->code
        and length $session_cookie->loginid <= 12)
    {
        return $session_cookie;
    }

    #not logged in
    return;
}

sub _build_bo_cookie {
    my $self = shift;

    my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login_bo;
    # if the user logged in.
    if (my $cookie = $self->cookie($cookie_name)) {
        return BOM::Platform::SessionCookie->from_value($cookie);
    } elsif (my $as_param = $self->param('staff')) {
        return BOM::Platform::SessionCookie->from_value($as_param);
    }

    return;
}

sub _build_ui_settings {
    my $self = shift;

    my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->settings;

    my $ui_settings = {};
    if (my $value = $self->cookie($cookie_name)) {
        try { $ui_settings = JSON::from_json($value); };
    }

    return $ui_settings;
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

sub is_office_staff {
    my $self = shift;
    my $ip   = $self->client_ip;
    my @office_ips = (
        '175.136.239.229',
        '211.24.127.133',
    );
    return 1 if grep {$_ eq $ip} @office_ips;

    return;
}

#Uses CGI::IDS to detect attacks from params.
sub detect_param_attacks {
    my $self = shift;

    my $ids = CGI::IDS->new(
        whitelist_file  => '/home/git/regentmarkets/bom-platform/config/ids_whitelist.xml',
        disable_filters => ['67']);
    #convert all arrays to a joined string to avoid stringify to return ARRAY string.
    my $impact = $ids->detect_attacks(request => {map { (ref $_ eq 'ARRAY') ? join(',', @$_) : $_ } %{$self->params}});
    if ($impact >= 4) {
        my $attacks_descriptions = "Attack impact is $impact ";
        foreach my $attack (@{$ids->get_attacks()}) {
            my $rules_broken = "";
            foreach my $rule (@{$attack->{matched_filters}}) {
                $rules_broken .= " - " . $ids->get_rule_description(rule_id => $rule);
            }
            $attacks_descriptions .= ", { [" . $attack->{key} . " => " . $attack->{value} . "] $rules_broken }";
        }

        my $ip = $self->client_ip;
        get_logger()->logcroak("[$ip] Detected IDS attacks on page " . $self->http_path . $attacks_descriptions);
    }

    return;
}

sub BUILD {
    my $self = shift;
    $self->detect_param_attacks();
    if ($self->http_method and not grep { $_ eq $self->http_method } qw/GET POST HEAD OPTIONS/) {
        get_logger()->logcroak($self->http_method . " is not an accepted request method");
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
