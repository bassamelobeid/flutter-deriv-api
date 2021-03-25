#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use URL::Encode qw( url_encode );
use HTML::Entities;

use BOM::User::Client;

use f_brokerincludeall;
use BOM::Backoffice::Request qw(request localize);
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Platform::Token;
use BOM::Config;
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $loginID = encode_entities(request()->param('show'));

# Issue new password to client
if (not $loginID) {
    code_exit_BO('Invalid loginID: please set loginID');
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => uc $loginID, db_operation => 'backoffice_replica'}) };
if (not $client) {
    code_exit_BO("[f_clientloginid_newpassword cgi] bad client $loginID");
}

my $email            = $client->email;
my $client_name      = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
my $has_social_login = $client->user->{has_social_signup};

if (not $email) {
    code_exit_BO('Invalid account: email address not set');
}

my $token = BOM::Platform::Token->new({
        email       => $email,
        expires_in  => 3600,
        created_for => 'reset_password'
    })->token;

my $brand = request()->brand;
my $lang  = request()->language;
my $link  = $brand->default_url() . "/redirect?action=reset_password&lang=$lang&code=$token";

print '<p class="success_message">Emailing change password link to ' . encode_entities($client_name) . ' at ' . encode_entities($email) . ' ...</p>';

my $result = send_email({
        from          => $brand->emails('support'),
        to            => $email,
        subject       => localize('Get a new [_1] account password', ucfirst $brand->name),
        template_name => $has_social_login ? "lost_password_has_social_login" : "lost_password",
        template_args => {
            name  => $client->first_name,
            title => $has_social_login ? localize("Forgot your social password?") : localize("Forgot your password? Let's get you a new one."),
            title_padding    => $has_social_login ? undef                         : 100,
            email            => $email,
            link             => $link,
            verification_url => $link,
            client_name      => $client_name =~ /^ *$/ ? 'there' : $client_name,
            website_name     => ucfirst $brand->name,
            brand_name       => ucfirst $brand->name,
        },
        template_loginid      => $loginID,
        use_email_template    => 1,
        email_content_is_html => 1,
        use_event             => 1,
    });

print '<p>New password issuance RESULT: ' . ($result) ? 'success' : 'fail' . '</p>';

print '<p>Done.</p>';

code_exit_BO();
