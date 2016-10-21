package BOM::Platform::Context::Request::Builders;

use Moose::Role;
use CGI::Cookie;
use Data::Validate::IP;

sub from_mojo {
    my $args    = shift;
    my $request = $args->{mojo_request};

    return unless ($request);

    ## put back some ENV b/c we use it in our other modules like BOM::System::AuditLog
    %ENV = (%ENV, %{$request->env});    ## no critic (Variables::RequireLocalizedPunctuationVars)
    __SetEnvironment();

    $args->{_ip} = '';
    if ($main::ENV{'REMOTE_ADDR'}) {
        $args->{_ip} = $main::ENV{'REMOTE_ADDR'};
    }

    if (not $args->{_ip} and $request->headers->header('x-forwarded-for')) {
        my @ips = split(/,\s*/, $request->headers->header('x-forwarded-for'));
        $args->{_ip} = $ips[0] if Data::Validate::IP::is_ipv4($ips[0]);
    }

    $args->{domain_name} = $request->url->to_abs->host;

    my $client_country = lc($request->headers->header('CF-IPCOUNTRY') || 'aq');
    $client_country = 'aq' if ($client_country eq 'xx');
    $args->{country_code} = $client_country;

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
