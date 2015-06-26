package BOM::Platform::Context::Request::Urls;

use Moose::Role;
use Mojo::URL;
use YAML::XS;
use BOM::Platform::Runtime;

sub domain {
    my $self   = shift;
    my $domain = $self->domain_name;

    if ($domain eq 'localhost') {
        $domain = $self->_build_domain_name;
    }

    $domain =~ s/[a-zA-Z0-9\-]+\.([a-zA-Z0-9\-]+\.[a-zA-Z0-9\-]+)/$1/;
    return $domain;
}

sub url_for {
    my ($self, @args) = @_;

    my $url = Mojo::URL->new($args[0] || '');
    my $query       = $args[1] || {};
    my $domain_type = $args[2] || {};
    my $internal    = $args[3] || {};

    $self->_find_domain_type($url->path, $domain_type);
    if ($domain_type->{static}) {
        my $path = $url->path;
        $path =~ s/^\///;
        my $complete_path;

        if ($internal->{internal_static}) {
            $complete_path = Mojo::URL->new(BOM::Platform::Runtime->instance->app_config->cgi->backoffice->static_url);
        } else {
            $complete_path = Mojo::URL->new(BOM::Platform::Context::request()->website->config->get('static.url'));
        }
        $complete_path = $complete_path->to_string . $path;
        $url           = $url->parse($complete_path);
    } else {
        $url->query($query);

        if ($domain_type->{cgi} or $domain_type->{bo}) {
            my $path = $url->path;

            if ($domain_type->{bo} and $path !~ /backoffice/) {
                $path = 'backoffice/' . $path;
            }

            if ($self->_is_page_cached($url->path)) {
                $path = '/c/' . $path;
            } else {
                $path = '/d/' . $path;
            }

            $path =~ s/\/\//\//g;
            $url->path($path);
        } elsif ($url->path !~ /^\//) {
            my $path = $url->path;
            $url->path("/$path");
        }

        if (not exists $domain_type->{no_host}) {
            my $domain = $self->domain_for($domain_type);
            $url->host($domain);
        }

        #Add Language to URL
        if (not $domain_type->{no_lang}) {
            $url->query([l => $self->language]);
        }
    }

    #Force https, only if we are building a full url
    if ($url->host) {
        $url->scheme('https');
    }

    return $url;
}

sub domain_for {
    my $self        = shift;
    my $domain_type = shift;

    my $domain = $self->website->primary_url;
    if (defined $domain_type) {
        if ($domain_type->{dealing}) {
            $domain = $self->_dealing_domain;
        } elsif ($domain_type->{localhost}) {
            $domain = $self->_localhost_domain;
        } elsif ($domain_type->{bo} or $self->backoffice) {
            $domain = $self->domain_name;
        }
    }

    return $domain;
}

sub _find_domain_type {
    my $self        = shift;
    my $path        = shift;
    my $domain_type = shift;

    #Select domain_type base on path
    if ($path) {
        if ($path =~ /^(xsl|temp)/) {
            $domain_type->{localhost} = 1;
            $domain_type->{no_lang}   = 1;
        } elsif ($path =~ /^errors/ or $path =~ /\.appcache/) {
            $domain_type->{direct}  = 1;
            $domain_type->{no_lang} = 1;
        } elsif ($path =~ /\.(?!cgi)/) {
            $domain_type->{static} = 1;
        } elsif ($path =~ /backoffice/) {
            $domain_type->{bo}      = 1;
            $domain_type->{cgi}     = 1;
            $domain_type->{no_lang} = 1;
        } elsif ($path =~ 'f_onlineid') {
            $domain_type->{dealing} = 1;
        } elsif ($path =~ /\.cgi/) {
            $domain_type->{cgi} = 1;
        }
    } else {
        $domain_type->{frontend} = 1;
    }

    if ($domain_type->{bo}) {
        $domain_type->{no_lang} = 1;
    }

    return;
}

has [qw(_page_caching_rules _dealing_domain _localhost_domain)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _is_page_cached {
    my $self = shift;
    my $path = shift;

    if ($path =~ /\.cgi/) {
        $path =~ s/^\///g;
    } elsif ($path !~ /^\//) {
        $path = "/$path";
    }

    my $cache_control = $self->_page_caching_rules->{$path};
    if ($cache_control->{"header"} and $cache_control->{"header"}->{'Cache-Control'} =~ /public/) {
        return 1;
    }

    return;
}

sub _build__page_caching_rules {
    my $self = shift;
    return YAML::XS::LoadFile('/home/git/regentmarkets/bom/config/files/page_caching_rules.yml');
}

sub _build__dealing_domain {
    my $self = shift;
    return $self->broker->server->name . '.' . $self->domain;
}

sub _build__localhost_domain {
    my $self = shift;
    return BOM::Platform::Runtime->instance->hosts->localhost->name . '.' . $self->domain;
}

1;

=head1 COPYRIGHT

(c) 2013-, RMG Tech (Malaysia) Sdn Bhd

=cut
