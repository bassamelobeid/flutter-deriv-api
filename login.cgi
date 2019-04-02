#!/etc/rmg/bin/perl
package main;

#official globals
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use CGI;
use Auth::DuoWeb;
use BOM::Config::Runtime;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::PlackHelpers qw( http_redirect PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Config;
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
        BOM::Config::third_party()->{duosecurity}->{ikey}, BOM::Config::third_party()->{duosecurity}->{skey},
        BOM::Config::third_party()->{duosecurity}->{akey}, request()->param('sig_response'),
    );

    $try_to_login = ($email eq request()->param('email'));
}
if (defined(request()->param('backprice'))) {
    my $bo_cookies = BOM::Backoffice::Cookie::build_cookies({
        backprice => request()->param('backprice'),
    });
    PrintContentType({'cookies' => $bo_cookies});
} elsif ($try_to_login and my $staff = BOM::Backoffice::Auth0::login(request()->param('access_token'))) {
    my $bo_cookies = BOM::Backoffice::Cookie::build_cookies({
        auth_token => request()->param('access_token'),
    });

    PrintContentType({'cookies' => $bo_cookies});
} elsif (request()->param('whattodo') eq 'logout') {
    my $expire_cookies = BOM::Backoffice::Cookie::expire_cookies();
    PrintContentType({'cookies' => $expire_cookies});

    BOM::Backoffice::Auth0::logout();
    print '<script>window.location = "' . request()->url_for('backoffice/login.cgi') . '"</script>';
    code_exit_BO();
} elsif (BOM::Backoffice::Auth0::get_staff()) {
    http_redirect(request()->url_for("backoffice/f_broker_login.cgi"));
}
BrokerPresentation('STAFF LOGIN PAGE');

#httpd_redirect will not push the cookies header.
print '<script>window.location = "' . request()->url_for('backoffice/f_broker_login.cgi') . '"</script>';

code_exit_BO();
