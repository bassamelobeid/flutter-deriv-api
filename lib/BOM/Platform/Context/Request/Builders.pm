package BOM::Platform::Context::Request::Builders;

use Moose::Role;
use CGI::Cookie;
use Data::Validate::IP;

=head2 from_cgi

Populate fields from a CGI request - note that this is only used in the backoffice code currently.

Eventually this and C<__SetEnvironment> should be removed entirely, so please consider that before
attempting to refactor this module.

=cut

sub from_cgi {
    my $args = shift;

    __SetEnvironment();

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
        $args->{_ip} = $client_ip;
    }

    if (my $host = $main::ENV{'HTTP_HOST'}) {
        $host =~ s/:\d+$//;
        $args->{domain_name} = $host;
    }

    if (my $start_time = $main::ENV{'REQUEST_STARTTIME'}) {
        $args->{start_time} = $start_time;
    }

    if ($0 =~ /bom-backoffice/) {
        $args->{backoffice} = 1;
    }

    $args->{from_ui} = 1;

    return BOM::Platform::Context::Request->new($args);
}

=head2 _remote_ip

Attempt to extract the client's public-facing IP address from the environment or request.

=cut

sub _remote_ip {
    my ($request) = @_;
    my $headers = $request->headers;
    # CF-Connecting-IP is mentioned here: https://support.cloudflare.com/hc/en-us/articles/200170986-How-does-CloudFlare-handle-HTTP-Request-headers-
    # Note that we will need to change this if switching to a different provider.
    my @candidates = ($headers->header('cf-connecting-ip'));
    push @candidates, do {
        # In this header, we expect:
        # client internal IP,maybe client external IP,any upstream proxies,cloudflare
        # We're interested in the IP address of whoever hit CloudFlare, so we drop the last one
        # then take the next one after that.
        my @ips = split /\s*,\s*/, $headers->header('x-forwarded-for');
        pop @ips;
        $ips[-1]
    };

    # Fall back to what our upstream (nginx) detected
    push @candidates, $request->env->{REMOTE_ADDR};
    for my $ip (@candidates) {
        # Eventually we'll want ::is_ip instead, but that requires IPv6 support in the database
        return $ip if Data::Validate::IP::is_ipv4($ip);
    }
    return '';
}

sub from_mojo {
    my $args    = shift;
    my $request = $args->{mojo_request};

    return unless ($request);

    # put back some ENV b/c we use it in our other modules like BOM::System::AuditLog

    ## no critic (Variables::RequireLocalizedPunctuationVars)
    %ENV = (%ENV, %{$request->env});
    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $ENV{REMOTE_ADDR} = $args->{_ip} = _remote_ip($request);

    $args->{domain_name} = $request->url->to_abs->host;

    my $client_country = lc($request->headers->header('CF-IPCOUNTRY') || 'aq');
    $client_country = 'aq' if ($client_country eq 'xx');
    $args->{country_code} = $client_country;
    $args->{from_ui}      = 1;

    return BOM::Platform::Context::Request->new($args);
}

sub __SetEnvironment {
    if (
        not $ENV{'REMOTE_ADDR'}

        # REMOTE_ADDR not set for whatever reason
        or $ENV{'REMOTE_ADDR'} =~ /\Q127.0.0.1\E/

        # client IP showing up as same as server IP
        or ($ENV{'SERVER_ADDR'} and $ENV{'REMOTE_ADDR'} eq $ENV{'SERVER_ADDR'}))
    {
        # extract client IP from X-Forwarded-For
        if (defined $ENV{'HTTP_X_FORWARDED_FOR'}) {
            $ENV{'HTTP_X_FORWARDED_FOR'} =~ s/\s//g;    ## no critic
            my @ips = split(/,\s*/, $ENV{'HTTP_X_FORWARDED_FOR'});
            shift @ips while ($ips[0] and $ips[0] =~ /^(192|10|172|127)\./);
            my $real_client_ip = $ips[0];
            if (defined $real_client_ip
                and $real_client_ip =~ /^(\d+\.\d+\.\d+\.\d+)$/)
            {
                $ENV{'REMOTE_ADDR'} = $1;               ## no critic
            }
        }
    }
    return;
}

1;

=head1 COPYRIGHT

(c) 2013-, RMG Tech (Malaysia) Sdn Bhd

=cut
