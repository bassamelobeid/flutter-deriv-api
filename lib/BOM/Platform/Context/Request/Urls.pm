package BOM::Platform::Context::Request::Urls;

use Memoize;
use Moose::Role;
use Mojo::URL;

use BOM::Platform::Runtime;
use BOM::Platform::Context;
use BOM::Platform::Static::Config;
use BOM::System::Config;

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
    my $query = $args[1] || {};
    my $domain_type = _get_domain_type($url->path, (($args[2] ? %{$args[2]} : ())));
    my $internal = $args[3] || {};

    if ($domain_type->{static}) {
        my $path = $url->path;
        $path =~ s/^\///;
        my $complete_path;

        if ($internal->{internal_static}) {
            $complete_path = Mojo::URL->new(BOM::Platform::Runtime->instance->app_config->cgi->backoffice->static_url);
        } else {
            $complete_path = Mojo::URL->new(BOM::Platform::Static::Config::get_static_url());
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
            $path = '/d/' . $path;
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
        if ($query->{l}) {
            $url->query([l => $query->{l}]);
        } elsif (not $domain_type->{no_lang}) {
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
    my $self = shift;

    my @host_name   = split(/\./, Sys::Hostname::hostname);
    my $server_name = $host_name[0];

    if ($server_name =~ /^(qa\d+)$/) {
        return "www.binary$1.com";
    }
    return $server_name . '.binary.com';
}

memoize('_get_domain_type');

sub _get_domain_type {
    my ($path, %defaults) = @_;
    my $domain_type = {%defaults};

    #Select domain_type base on path
    if ($path) {
        if ($path =~ /^(xsl|temp)/) {
            $domain_type->{localhost} = 1;
            $domain_type->{no_lang}   = 1;
        } elsif ($path =~ /^errors/) {
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

    return $domain_type;
}

1;

=head1 COPYRIGHT

(c) 2013-, RMG Tech (Malaysia) Sdn Bhd

=cut
