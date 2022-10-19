package BOM::Platform::Context::Request::Builders;

use Moose::Role;
use CGI::Cookie;
use Data::Validate::IP;

use BOM::Platform::Context::Request;

=head2 _remote_ip

Attempt to extract the client's public-facing IP address from the environment or request.

Note that this only supports IPv4 at the moment.

=cut

sub _remote_ip {
    my ($request) = @_;
    my $headers = $request->headers;
    # CF-Connecting-IP is mentioned here: https://support.cloudflare.com/hc/en-us/articles/200170986-How-does-CloudFlare-handle-HTTP-Request-headers-
    # Note that we will need to change this if switching to a different provider.
    my @candidates = (
        # https://support.cloudflare.com/hc/en-us/articles/202494830-Pseudo-IPv4-Supporting-IPv6-addresses-in-legacy-IPv4-applications
        ($headers->header('cf-pseudo-ipv4')   // ()),
        ($headers->header('cf-connecting-ip') // ()),
        # https://support.cloudflare.com/hc/en-us/articles/206776727-What-is-True-Client-IP-
        ($headers->header('true-client-ip') // ()),
    );
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

    # put back some ENV b/c we use it in our other modules like BOM::User::AuditLog

    %ENV = (%ENV, %{$request->env});    ## no critic (RequireLocalizedPunctuationVars)

    $ENV{REMOTE_ADDR} = $args->{_ip} = _remote_ip($request);    ## no critic (RequireLocalizedPunctuationVars)

    $args->{domain_name} = $request->url->to_abs->host;

    my ($custom_header_country) = $request->headers->header('X-Client-Country') || '' =~ m/^([a-z]{2})$/i;
    my $client_country = lc($custom_header_country || $request->headers->header('CF-IPCOUNTRY') || 'aq');
    $client_country = 'aq' if ($client_country eq 'xx');
    $args->{country_code} = $client_country;

    return BOM::Platform::Context::Request->new($args);
}

1;
