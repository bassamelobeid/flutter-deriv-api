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
BrokerPresentation('ISSUE NEW PASSWORD TO ' . $loginID);

# Issue new password to client
if (not $loginID) {
    print 'Invalid loginID: please set loginID';
    code_exit_BO();
}

my $client = BOM::User::Client::get_instance({
        'loginid'    => uc $loginID,
        db_operation => 'replica'
    }) || die "[f_clientloginid_newpassword cgi] bad client $loginID";

my $email            = $client->email;
my $client_name      = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
my $has_social_login = $client->user->{has_social_signup};

if (not $email) {
    print 'Invalid account: email address not set';
    code_exit_BO();
}

my $token = BOM::Platform::Token->new({
        email       => $email,
        expires_in  => 3600,
        created_for => 'reset_password'
    })->token;

my $lang = request()->language;
my $link = "https://www.binary.com/" . lc($lang) . "/redirect.html?action=reset_password&lang=$lang&code=$token";

my $lost_pass_email;

my $brand = request()->brand;

my $email_template = $has_social_login ? "email/lost_password_has_social_login.html.tt" : "email/lost_password.html.tt";

BOM::Backoffice::Request::template()->process(
    $email_template,
    {
        link         => $link,
        client_name  => $client_name =~ /^ *$/ ? 'there' : $client_name,
        website_name => ucfirst BOM::Config::domain()->{default_domain},
    },
    \$lost_pass_email
);

# email link to client
Bar('emailing change password link to ' . $loginID);

print '<p class="success_message">Emailing change password link to ' . encode_entities($client_name) . ' at ' . encode_entities($email) . ' ...</p>';

my $result = send_email({
    from                  => $brand->emails('support'),
    to                    => $email,
    subject               => localize('Reset your [_1] account password', ucfirst BOM::Config::domain()->{default_domain}),
    message               => [$lost_pass_email,],
    template_loginid      => $loginID,
    use_email_template    => 1,
    email_content_is_html => 1,
});

print '<p>New password issuance RESULT: ' . ($result) ? 'success' : 'fail' . '</p>';

print '<p>Done.</p>';

code_exit_BO();
