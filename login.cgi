#!/usr/bin/perl
package main;

#official globals
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use CGI;
use BOM::Utility::DuoWeb;
use BOM::Platform::Runtime;
use BOM::Platform::Auth0;
use BOM::Platform::Plack qw( http_redirect PrintContentType );
use BOM::Platform::SessionCookie;
use BOM::Platform::Context qw(request);
use BOM::View::Backoffice::StaffPages;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

my $try_to_login;
my $passwd = request()->param('pass');

if (request()->param('sig_response')) {
    my $email = BOM::Utility::DuoWeb::verify_response(
        BOM::Platform::Runtime->instance->app_config->system->duoweb->IKEY, BOM::Platform::Runtime->instance->app_config->system->duoweb->SKEY,
        BOM::Platform::Runtime->instance->app_config->system->duoweb->AKEY, request()->param('sig_response'),
    );

    $try_to_login = ($email eq request()->param('email'));
}

if ($try_to_login and my $staff = BOM::Platform::Auth0::login(request()->param('access_token'))) {
    my $mycookie = session_cookie({
        loginid => BOM::Platform::Context::request()->broker->code,
        token   => request()->param('access_token'),
        clerk   => $staff->{nickname},
    });
    PrintContentType({'cookies' => $mycookie});
} elsif (request()->param('whattodo') eq 'logout') {
    my $mycookie = session_cookie({
        loginid => "",
        token   => "",
        clerk   => "",
        expires => 1,
    });
    BOM::Platform::Auth0::loggout();
    PrintContentType({'cookies' => $mycookie});
    print '<script>window.location = "' . request()->url_for('backoffice/login.cgi') . '"</script>';
    code_exit_BO();
} elsif (not BOM::Platform::Auth0::from_cookie()) {
    PrintContentType();
    BOM::View::Backoffice::StaffPages->instance->login();
    code_exit_BO();
} else {
    http_redirect(request()->url_for("backoffice/f_broker_login.cgi"));
}
BrokerPresentation('STAFF LOGIN PAGE');

#httpd_redirect will not push the cookies header.
print '<script>window.location = "' . request()->url_for('backoffice/f_broker_login.cgi') . '"</script>';

code_exit_BO();

sub session_cookie {
    my $args = shift;
    $args->{loginid} = uc $args->{loginid};
    my $expiry     = ($args->{expires}) ? $args->{expires} : '+30d';
    my $cookie     = BOM::Platform::SessionCookie->new($args);
    my $cookiename = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login_bo;

    my $login = CGI::cookie(
        -name    => $cookiename,
        -value   => $cookie->value,
        -expires => $expiry,
        -secure  => 1,
        -domain  => request()->cookie_domain,
        -path    => '/',
    );

    return [$login];
}

