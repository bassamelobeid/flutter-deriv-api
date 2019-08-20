package BOM::Backoffice::Request::Role;

use Moose::Role;
use Mojo::URL;
use Sys::Hostname;
use CGI::Cookie;
use BOM::Backoffice::Request::Base;

sub from_cgi {
    my $args = shift;

    _SetEnvironment();

    if ($args->{http_cookie}) {
        my %read_cookies = CGI::Cookie->parse($args->{http_cookie});
        $args->{cookies} //= {};
        foreach my $cookie (keys %read_cookies) {
            $args->{cookies}->{$cookie} = $read_cookies{$cookie}->value;
        }

        delete $args->{http_cookie};
    }

    my $client_country = lc($main::ENV{'HTTP_CF_IPCOUNTRY'} || 'aq');
    $client_country = 'aq' if ($client_country eq 'xx');
    $args->{country_code} = $client_country;

    if (my $client_ip = $main::ENV{'REMOTE_ADDR'}) {
        $args->{client_ip} = $client_ip;
    }

    if (my $host = $main::ENV{'HTTP_HOST'}) {
        $host =~ s/:\d+$//;
        $args->{domain_name} = $host;
    }

    $args->{from_ui} = 1;

    return BOM::Backoffice::Request::Base->new($args);
}

sub url_for {
    my ($self, @args) = @_;

    my $url = Mojo::URL->new($args[0] || '');
    my $query = $args[1] || {};

    if ($url->path =~ /.*\.cgi$/) {
        $url->query($query);
        $url->path('/d/' . $url->path);
        $url->host(_domain_for());
        # static files
    } else {
        $url->query($query);
        $url->path('/binary-static-backoffice/' . $url->path);
        $url->host('regentmarkets.github.io');
    }
    $url->scheme('https');

    return $url;
}

sub _SetEnvironment {
    if (
        not $ENV{'REMOTE_ADDR'}

        # REMOTE_ADDR not set for whatever reason
        or $ENV{'REMOTE_ADDR'} =~ /\Q127.0.0.1\E/

        # client IP showing up as same as server IP
        or ($ENV{'SERVER_ADDR'} and $ENV{'REMOTE_ADDR'} eq $ENV{'SERVER_ADDR'}))
    {
        # extract client IP from X-Forwarded-For
        if (defined $ENV{'HTTP_X_FORWARDED_FOR'}) {
            $ENV{'HTTP_X_FORWARDED_FOR'} =~ s/\s//g;
            my @ips = split(/,\s*/, $ENV{'HTTP_X_FORWARDED_FOR'});
            shift @ips while ($ips[0] and $ips[0] =~ /^(192|10|172|127)\./);
            my $real_client_ip = $ips[0];
            if (defined $real_client_ip
                and $real_client_ip =~ /^(\d+\.\d+\.\d+\.\d+)$/)
            {
                $ENV{'REMOTE_ADDR'} = $1;    ## no critic (RequireLocalizedPunctuationVars)
            }
        }
    }
    return;
}

sub _domain_for {
    my @host_name   = split(/\./, Sys::Hostname::hostname());
    my $server_name = $host_name[0];
    my $site        = lc(Brands->new(name => 'binary')->website_name);
    if ($server_name =~ /^(qa\d+)$/) {
        #TODO should change here ?
        return "www.binary$1.com" if $host_name[1] eq 'regentmarkets';
        return Sys::Hostname::hostname();
    }

    if ($server_name =~ /^backoffice.*$/) {
        return "backoffice.$site";
    }

    return $server_name . ".$site";
}

1;
