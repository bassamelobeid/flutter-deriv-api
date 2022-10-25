#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use URL::Encode qw( url_encode );
use HTML::Entities;
use BOM::Platform::Event::Emitter;
use BOM::User::Client;
use f_brokerincludeall;
use BOM::Backoffice::Request      qw(request localize);
use BOM::Platform::Email          qw(send_email);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit      ();
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
my $lang  = $client->user->preferred_language // request()->language;
my $link  = $brand->default_url() . "/redirect?action=reset_password&lang=$lang&code=$token";

print '<p class="success_message">Emailing change password link to ' . encode_entities($client_name) . ' at ' . encode_entities($email) . ' ...</p>';

my $result = BOM::Platform::Event::Emitter::emit(
    'reset_password_request',
    {
        loginid    => $client->loginid,
        properties => {
            email                 => $email,
            verification_url      => $link             // '',
            social_login          => $has_social_login // '',
            code                  => $token,
            language              => $lang,
            time_to_expire_in_min => 60,
            live_chat_url         => request()->brand->live_chat_url
        },
    });

$result = $result ? "success" : "fail";
print "<p>New password issuance RESULT: $result </p>";

code_exit_BO();
