#!/etc/rmg/bin/perl
package main;

#official globals
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use CGI;
use Auth::DuoWeb;
use BOM::Platform::Runtime;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::PlackHelpers qw( http_redirect PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::StaffPages;
use BOM::Platform::Config;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

if (not $ENV{'HTTP_USER_AGENT'} =~ /Chrome\/(\d+\.\d+\.\d+)\./ or $1 lt '55.0.2883') {
    print "Only newest Chrome browser is supported in backoffice.";
    code_exit_BO();
}

my $try_to_login;
my $passwd = request()->param('pass');

if (request()->param('sig_response')) {
    my $email = Auth::DuoWeb::verify_response(
        BOM::Platform::Config::third_party->{duosecurity}->{ikey}, BOM::Platform::Config::third_party->{duosecurity}->{skey},
        BOM::Platform::Config::third_party->{duosecurity}->{akey}, request()->param('sig_response'),
    );

    $try_to_login = ($email eq request()->param('email'));
}

if ($try_to_login and my $staff = BOM::Backoffice::Auth0::login(request()->param('access_token'))) {
    my $bo_cookies = BOM::Backoffice::Cookie::build_cookies({
        staff      => $staff->{nickname},
        auth_token => request()->param('access_token'),
    });

    PrintContentType({'cookies' => $bo_cookies});
} elsif (request()->param('whattodo') eq 'logout') {
    my $expire_cookies = BOM::Backoffice::Cookie::expire_cookies();
    PrintContentType({'cookies' => $expire_cookies});

    BOM::Backoffice::Auth0::logout();
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
