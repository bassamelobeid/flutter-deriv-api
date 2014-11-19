#!/usr/bin/perl
package main;

use strict 'vars';

use f_brokerincludeall;
use BOM::Utility::DuoWeb;
use BOM::Platform::Auth0;
use BOM::Platform::Plack qw( PrintContentType );
system_initialize();
PrintContentType();

my $access_token = BOM::Platform::Auth0::exchange_code(request()->param('code'));
my $staff        = BOM::Platform::Auth0::user_by_access_token($access_token);
if (not $staff) {
    print "Login failed";
    code_exit_BO();
}
my $post_action = "login.cgi";
my $email       = $staff->{email};
my $post_action = "login.cgi";

my $sig_request = BOM::Utility::DuoWeb::sign_request(
    BOM::Platform::Runtime->instance->app_config->system->duoweb->IKEY,
    BOM::Platform::Runtime->instance->app_config->system->duoweb->SKEY,
    BOM::Platform::Runtime->instance->app_config->system->duoweb->AKEY, $email,
);

if ($sig_request) {
    print qq~
    <!--- show second factor authentication page --->
    <!doctype html>
    <html>
     <head>
      <title>Please Authenticate</title>
      ~;

    BOM::Platform::Context::template->process('backoffice/global/javascripts.html.tt',
        {javascript => BOM::View::JavascriptConfig->instance->config_for()})
      || die BOM::Platform::Context::template->error;
    foreach my $js_file (BOM::View::JavascriptConfig->instance->bo_js_files_for($0)) {
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
         <input type="hidden" name="email" value="$email">
         <input type="hidden" name="post_action" value="$post_action">
         <input type="hidden" name="brokercode" value="$brokercode" />
        </form>
       </body>
      </html>
      <!--- two factor authentication --->
    ~;
}

code_exit_BO();
