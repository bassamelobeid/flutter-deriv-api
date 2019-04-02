package BOM::Backoffice::Cookie;

use warnings;
use strict;

use CGI::Cookie;
use CGI::Util;
use BOM::Backoffice::Request qw(request);
use BOM::Config;

my @base_cookies_list = qw/staff auth_token/;

sub _build_cookie {
    return CGI::cookie(
        -name     => $_[0],
        -value    => $_[1],
        -expires  => $_[2],
        -secure   => 1,
        -httponly => 1,
        -domain   => request()->cookie_domain,
        -path     => '/',
    );
}

sub build_cookies {
    my $values = shift // {};
    return [map { defined($values->{$_}) ? _build_cookie($_, $values->{$_}, '+30d') : () }
            (@base_cookies_list, BOM::Config::on_qa() ? 'backprice' : ())];
}

# expire cookies, by setting "expires" in the past
sub expire_cookies {
    return [map { _build_cookie($_, undef, '-1d') } @base_cookies_list];
}

sub get_staff {
    die 'broken';
}

sub get_auth_token {
    return get_cookie('auth_token');
}

sub get_cookie {
    my $name = shift;

    my %bo_cookies = CGI::Cookie->fetch;
    my $value;

    if ($bo_cookies{$name}) {
        $value = CGI::Util::escape($bo_cookies{$name}->value);
    }
    return $value;
}

1;
