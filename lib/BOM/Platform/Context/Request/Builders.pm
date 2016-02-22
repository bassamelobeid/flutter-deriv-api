package BOM::Platform::Context::Request::Builders;

use Moose::Role;
use CGI::Cookie;
use Data::Validate::IP;

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

    if (my $http_modified = $main::ENV{HTTP_IF_MODIFIED_SINCE}) {
        $args->{http_modified} = $http_modified;
    }

    $args->{from_ui} = 1;

    return BOM::Platform::Context::Request->new($args);
}

sub from_mojo {
    my $args    = shift;
    my $request = $args->{mojo_request};

    return unless ($request);

    ## put back some ENV b/c we use it in our other modules like BOM::System::AuditLog
    %ENV = (%ENV, %{$request->env});    ## no critic (Variables::RequireLocalizedPunctuationVars)
    __SetEnvironment();

    $args->{_ip} = '';
    if ($request->headers->header('x-forwarded-for')) {
        my @ips = split(/,\s*/, $request->headers->header('x-forwarded-for'));
        $args->{_ip} = $ips[0] if Data::Validate::IP::is_ipv4($ips[0]);
    }
    if (not $args->{_ip} and $main::ENV{'REMOTE_ADDR'}) {
        $args->{_ip} = $main::ENV{'REMOTE_ADDR'};
    }

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
            if (defined $real_client_ip and $real_client_ip =~ /^(\d+\.\d+\.\d+\.\d+)$/) {
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
