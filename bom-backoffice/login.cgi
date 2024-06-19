#!/etc/rmg/bin/perl
package main;

#official globals
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use CGI;

use BOM::Config::Runtime;
use BOM::Backoffice::Auth;
use BOM::Backoffice::PlackHelpers qw( http_redirect PrintContentType check_browser_version);
use BOM::Backoffice::Request      qw(request);
use BOM::Config;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

if (!check_browser_version(BOM::Config::Runtime->instance->app_config->system->browser->minimum_supported_chrome_version)) {
    print "Only newest Chrome browser is supported in backoffice.";
    code_exit_BO();
}

if (request()->param('whattodo') eq 'logout') {
    my $expire_cookies = BOM::Backoffice::Cookie::expire_cookies();
    PrintContentType({'cookies' => $expire_cookies});

    my $staff = BOM::Backoffice::Auth::get_staff();

    BOM::Backoffice::Auth::logout();
    print '<script>window.location = "' . BOM::Backoffice::Auth::logout_url() . '" </script>';
    code_exit_BO();
} elsif (BOM::Backoffice::Auth::get_staff()) {
    http_redirect(request()->url_for("backoffice/f_broker_login.cgi"));
} else {
    my $staff = BOM::Backoffice::Auth::login();

    my $bo_cookies = BOM::Backoffice::Cookie::build_cookies({
        auth_token => $staff->{token},
    });

    PrintContentType({'cookies' => $bo_cookies});
}

BrokerPresentation('STAFF LOGIN PAGE');

#httpd_redirect will not push the cookies header.
print '<script>window.location = "' . request()->url_for('backoffice/f_broker_login.cgi') . '"</script>';

code_exit_BO();
