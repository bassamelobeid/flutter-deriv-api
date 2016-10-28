package BOM::Backoffice::Cookie;

use warnings;
use strict;

use CGI::Cookie;
use CGI::Util;
use BOM::Backoffice::Request qw(request);

sub build_cookies {
    my $args = shift;

    my $staff      = $args->{staff};
    my $auth_token = $args->{auth_token};

    my $staff_cookie = CGI::cookie(
        -name     => 'staff',
        -value    => $staff,
        -expires  => '+30d',
        -secure   => 1,
        -httponly => 1,
        -domain   => request()->cookie_domain,
        -path     => '/',
    );

    my $token_cookie = CGI::cookie(
        -name     => 'auth_token',
        -value    => $auth_token,
        -expires  => '+30d',
        -secure   => 1,
        -httponly => 1,
        -domain   => request()->cookie_domain,
        -path     => '/',
    );

    return [$staff_cookie, $token_cookie];
}

sub expire_cookies {
    # expire cookies, by setting "expires" in the past
    my $staff_cookie = CGI::cookie(
        -name     => 'staff',
        -expires  => '-1d',
        -secure   => 1,
        -httponly => 1,
        -domain   => request()->cookie_domain,
        -path     => '/',
    );

    my $token_cookie = CGI::cookie(
        -name     => 'auth_token',
        -expires  => '-1d',
        -secure   => 1,
        -httponly => 1,
        -domain   => request()->cookie_domain,
        -path     => '/',
    );

    return [$staff_cookie, $token_cookie];
}

sub get_staff {
    return __get_cookie('staff');
}

sub get_auth_token {
    return __get_cookie('auth_token');
}

sub __get_cookie {
    my $name = shift;

    my %bo_cookies = CGI::Cookie->fetch;
    my $value;

    if ($bo_cookies{$name}) {
        $value = CGI::Util::escape($bo_cookies{$name}->value);
    }
    return $value;
}

1;
