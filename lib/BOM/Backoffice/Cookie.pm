package BOM::Backoffice::Cookie;

use warnings;
use strict;
use CGI::Cookie;
use CGI::Util;

sub build_cookies {
    my $args = shift;

    my $staff = $args->{staff};
    my $auth_token = $args->{auth_token};

    my $staff_cookie = CGI::cookie(
        -name    => 'staff',
        -value   => $staff,
        -expires => '+30d',
        -secure  => 1,
        -domain  => request()->cookie_domain,
        -path    => '/',
    );

    my $token_cookie = CGI::cookie(
        -name    => 'auth_token',
        -value   => $auth_token,
        -expires => '+30d',
        -secure  => 1,
        -domain  => request()->cookie_domain,
        -path    => '/',
    );

    return [$staff_cookie, $token_cookie];
}

sub expire_cookies {
    # expire cookies, by setting "expires" in the past
    my $staff_cookie = CGI::cookie(
        -name    => 'staff',
        -expires => '-1d',
        -secure  => 1,
        -domain  => request()->cookie_domain,
        -path    => '/',
    );

    my $token_cookie = CGI::cookie(
        -name    => 'auth_token',
        -expires => '-1d',
        -secure  => 1,
        -domain  => request()->cookie_domain,
        -path    => '/',
    );

    return [$staff_cookie, $token_cookie];
}

sub get_staff {
    my %bo_cookies = CGI::Cookie->fetch;

    my $staff;
    if ($bo_cookies->{staff}) {
        $staff = CGI::Util::escape($bo_cookies{staff}->value);
    }
    return $staff;
}

sub set_staff_cookie {
}

1;
