#!/usr/bin/perl
package main;
use strict 'vars';

use URL::Encode qw( url_encode );
use Digest::MD5;

use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Context;
use BOM::Platform::Persistence::DAO::Utils::ClientPasswordRecovery;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

my $loginID = request()->param('show');
BrokerPresentation('ISSUE NEW PASSWORD TO ' . $loginID);

BOM::Platform::Auth0::can_access(['CS']);

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

my $hcstring = $email . time . 'request_password';
my $token    = Digest::MD5::md5_hex($hcstring);

my $success =
    BOM::Platform::Persistence::DAO::Utils::ClientPasswordRecovery::force_client_recovery_password_email_status($client->loginid, $token, $email);

my $lang = request()->language;

my $link = request()->url_for(
    'lost_password.cgi',
    {
        action => 'recover',
        email  => url_encode($email),
        token  => $token,
        login  => $client->loginid
    });

my $lost_pass_email;
BOM::Platform::Context::template->process(
    "email/lost_password.html.tt",
    {
        'link'     => $link,
        'helpdesk' => BOM::Platform::Context::request()->website->config->get('customer_support.email'),
    },
    \$lost_pass_email
);

if (not $success) {
    print 'Could not set client recovery stage properly';
    code_exit_BO();
}

# email link to client
Bar('emailing change password link to ' . $loginID);

print '<p class="success_message">Emailing change password link to ' . $client_name . ' at ' . $email . ' ...</p>';

my $result = send_email({
    from               => BOM::Platform::Context::request()->website->config->get('customer_support.email'),
    to                 => $email,
    subject            => localize('New Password Request'),
    message            => [$lost_pass_email,],
    use_email_template => 1,
});

print '<p>New password issuance RESULT: ' . ($result) ? 'success' : 'fail' . '</p>';

print '<p>Done.</p>';

code_exit_BO();
