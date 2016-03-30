#!/usr/bin/perl
package main;
use strict 'vars';

use URL::Encode qw( url_encode );

use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Context;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use BOM::Platform::Token::Verification;
use BOM::Platform::Static::Config;
use BOM::System::Config;
BOM::Platform::Sysinit::init();

PrintContentType();

my $loginID = request()->param('show');
BrokerPresentation('ISSUE NEW PASSWORD TO ' . $loginID);

BOM::Backoffice::Auth0::can_access(['CS']);

# Issue new password to client
if (not $loginID) {
    print 'Invalid loginID: please set loginID';
    code_exit_BO();
}

my $client      = BOM::Platform::Client::get_instance({'loginid' => $loginID}) || die "[f_clientloginid_newpassword cgi] bad client $loginID";
my $email       = $client->email;
my $client_name = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;

if (not $email) {
    print 'Invalid account: email address not set';
    code_exit_BO();
}

my $lang = request()->language;

my $link;
my $token = BOM::Platform::Token::Verification->new({
        email       => $email,
        expires_in  => 3600,
        created_for => 'reset_password'
    })->token;

# don't want to touch url_for for this only, need this change else reset password url will have backoffice.binary.com if send from production
if (BOM::System::Config::node->{node}->{www2}) {
    $link = 'https://www2.binary.com/user/validate_link?verify_token=' . $token . '&l=' . uc $lang;
} elsif (BOM::System::Config::env =~ /^production$/) {
    $link = 'https://www.binary.com/user/validate_link?verify_token=' . $token . '&l=' . uc $lang;
} else {
    $link = request()->url_for('/user/validate_link', {verify_token => $token});
}

my $lost_pass_email;
BOM::Platform::Context::template->process(
    "email/lost_password.html.tt",
    {
        'link'     => $link,
        'helpdesk' => BOM::Platform::Static::Config::get_customer_support_email(),
    },
    \$lost_pass_email
);

# email link to client
Bar('emailing change password link to ' . $loginID);

print '<p class="success_message">Emailing change password link to ' . $client_name . ' at ' . $email . ' ...</p>';

my $result = send_email({
    from               => BOM::Platform::Static::Config::get_customer_support_email(),
    to                 => $email,
    subject            => localize('New Password Request'),
    message            => [$lost_pass_email,],
    template_loginid   => $loginID,
    use_email_template => 1,
});

print '<p>New password issuance RESULT: ' . ($result) ? 'success' : 'fail' . '</p>';

print '<p>Done.</p>';

code_exit_BO();
