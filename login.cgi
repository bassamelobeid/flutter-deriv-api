#!/usr/bin/perl
package main;

#official globals
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use CGI;
use Auth::DuoWeb;
use BOM::Platform::Runtime;
use BOM::Backoffice::Auth0;
use BOM::Platform::Plack qw( http_redirect PrintContentType );
use BOM::Platform::SessionCookie;
use BOM::Platform::Context qw(request);
use BOM::StaffPages;
use BOM::System::Config;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

if (not $ENV{'HTTP_USER_AGENT'} =~ /Chrome\/(\d+\.\d+\.\d+)\./ or $1 lt '50.0.2661') {
    print "Only newest Chrome browser is supported in backoffice.";
    code_exit_BO();
}

my $try_to_login;
my $passwd = request()->param('pass');

if (request()->param('sig_response')) {
    my $email = Auth::DuoWeb::verify_response(
        BOM::System::Config::third_party->{duosecurity}->{ikey},
        BOM::System::Config::third_party->{duosecurity}->{skey},
        BOM::System::Config::third_party->{duosecurity}->{akey},
        request()->param('sig_response'),
    );

    $try_to_login = ($email eq request()->param('email'));
}

if ($try_to_login and my $staff = BOM::Backoffice::Auth0::login(request()->param('access_token'))) {
    my $mycookie = session_cookie({
        loginid    => BOM::Platform::Context::request()->broker->code,
        auth_token => request()->param('access_token'),
        clerk      => $staff->{nickname},
        email      => request()->param('email'),
    });
    PrintContentType({'cookies' => $mycookie});
} elsif (request()->param('whattodo') eq 'logout') {
     BOM::Platform::Context::request()->bo_cookie->end_session;
    BOM::Backoffice::Auth0::loggout();
    print '<script>window.location = "' . request()->url_for('backoffice/login.cgi') . '"</script>';
    code_exit_BO();
} elsif (not BOM::Backoffice::Auth0::from_cookie()) {
    PrintContentType();
    BOM::StaffPages->instance->login();
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
        -value   => $cookie->token,
        -expires => $expiry,
        -secure  => 1,
        -domain  => request()->cookie_domain,
        -path    => '/',
    );

    return [$login];
}
