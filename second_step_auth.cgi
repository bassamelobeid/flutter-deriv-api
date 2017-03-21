#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use f_brokerincludeall;
use Auth::DuoWeb;
use BOM::Platform::Config;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::JavascriptConfig;

BOM::Backoffice::Sysinit::init();
PrintContentType();

my $access_token = request()->param('token');
my $staff        = BOM::Backoffice::Auth0::user_by_access_token($access_token);

if (not $staff) {
    print "Login failed";
    code_exit_BO();
}

my $post_action = "login.cgi";

my $sig_request = Auth::DuoWeb::sign_request(
    BOM::Platform::Config::third_party->{duosecurity}->{ikey},
    BOM::Platform::Config::third_party->{duosecurity}->{skey},
    BOM::Platform::Config::third_party->{duosecurity}->{akey},
    $staff->{email},
);

if ($sig_request) {
    print qq~
    <!--- show second factor authentication page --->
    <!doctype html>
    <html>
     <head>
      <title>Please Authenticate</title>
      ~;

    foreach my $js_file (BOM::JavascriptConfig->instance->bo_js_files_for($0)) {
        print '<script type="text/javascript" src="' . $js_file . '"></script>';
    }

    my $brokercode = request()->param('brokercode');
    print qq~
       <script>
        Duo.init
        ({
         'host'         : 'api-bfe8fe37.duosecurity.com',
         'sig_request'  : '$sig_request',
         'post_action'  : '$post_action',
        });
        </script>
      </head>
       <body>
        <center>
         <h2>Authenticate</h2>
          <iframe id="duo_iframe" width="620" height="330" frameborder="0"></iframe>
        </center>
        <form method="POST" id="duo_form">
         <input type="hidden" name="whattodo" value="login" />
         <input type="hidden" name="access_token" value="$access_token">
         <input type="hidden" name="email" value="$staff->{email}">
         <input type="hidden" name="post_action" value="$post_action">
         <input type="hidden" name="brokercode" value="$brokercode" />
        </form>
       </body>
      </html>
      <!--- two factor authentication --->
    ~;
}

code_exit_BO();
