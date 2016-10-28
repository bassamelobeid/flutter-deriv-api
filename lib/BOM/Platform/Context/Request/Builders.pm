package BOM::Platform::Context::Request::Builders;

use Moose::Role;
use CGI::Cookie;
use Data::Validate::IP;

use BOM::Platform::Context::Request;

=head2 _remote_ip

Attempt to extract the client's public-facing IP address from the environment or request.

=cut

sub _remote_ip {
    my ($request) = @_;
    my $headers = $request->headers;
    # CF-Connecting-IP is mentioned here: https://support.cloudflare.com/hc/en-us/articles/200170986-How-does-CloudFlare-handle-HTTP-Request-headers-
    # Note that we will need to change this if switching to a different provider.
    my @candidates = ($headers->header('cf-connecting-ip') // ());
    push @candidates, do {
        # In this header, we expect:
        # client internal IP,maybe client external IP,any upstream proxies,cloudflare
        # We're interested in the IP address of whoever hit CloudFlare, so we drop the last one
        # then take the next one after that.
        my @ips = split /\s*,\s*/, $headers->header('x-forwarded-for');
        pop @ips;
        $ips[-1];
    } if $headers->header('x-forwarded-for');

    # Fall back to what our upstream (nginx) detected
    push @candidates, $request->env->{REMOTE_ADDR} // ();
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

    return BOM::Platform::Context::Request->new($args);
}

1;
