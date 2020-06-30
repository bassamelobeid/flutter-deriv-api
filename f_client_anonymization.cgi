#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Date::Utility;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Platform::Event::Emitter;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation("CLIENT ANONYMIZATION");

my $input = request()->params;
my $clerk = BOM::Backoffice::Auth0::get_staffname();

Bar("MAKE DUAL CONTROL CODE");
print
    "To anonymize a client we require 2 staff members to authorise. One staff member needs to generate a 'Dual Control Code' that is then used by the other staff member when initiating the anonymization.<br><br>";
print "<form id='generateDCC' action='"
    . request()->url_for('backoffice/f_client_anonymization_dcc.cgi')
    . "' method='get' class='bo_ajax_form'>"
    . "<input type='hidden' name='l' value='EN'>"
    . "Transaction type: <select name='transtype'>"
    . "<option value='Anonymize client'>Anonymize client details</option>"
    . "<option value='Delete customerio record'>Delete client customerio record</option>"
    . "</select><br><br>"
    . "Loginid : <input type='text' name='clientloginid' size='15' placeholder='required' data-lpignore='true' />"
    . "<br><br><input type='submit' value='Make Dual Control Code (by "
    . encode_entities($clerk) . ")'>"
    . "</form>";

Bar("START ANONYMIZATION");
print "<b>WARNING : THIS WILL RESULT IN PERMANENT DATA LOSS</b><br><br>
    Anonymization will make the following changes:<br>
    <ul>
    <li>Replace first and last names with deleted+loginid</li>
    <li>Replace Address1 and 2 including town/city and postcode with deleted</li>
    <li>Replace Tax Identification Number with deleted</li>
    <li>Replace secret question and answer with deleted</li>
    <li>Replace email address with loginid\@deleted.binary.user</li>
    <li>Replace telephone number with empty string</li>
    <li>Replace all personal data and IP address in audit trail(history of changes) in BO with deleted</li>
    <li>Replace payment remarks for bank wires transactions available on the client's account statement in BO with `deleted wire payment</li>
    <li>Delete all documents from database and S3</li>
    </ul>
    <hr>";
my $loginid  = $input->{clientloginid} // '';
my $prev_dcc = $input->{DCcode}        // '';
print "<form id='clientAnonymization' action='"
    . request()->url_for('backoffice/f_client_anonymization.cgi')
    . "' method='post'>"
    . "<input type='hidden' name='l' value='EN'>"
    . "Loginid : <input type='text' name='clientloginid' size='15' placeholder='required' data-lpignore='true' value='"
    . $loginid . "'>"
    . "<br><br>DCC : <input type='text' name='DCcode' size='50' placeholder='required' data-lpignore='true' value='"
    . $prev_dcc . "'>"
    . "<br><br><input type='checkbox' name='verification' id='chk_verify' value='true'> <label for='chk_verify'>I understand this action is irreversible ("
    . encode_entities($clerk)
    . ")</label><br><br><input type='submit' name='transtype' value='Anonymize client'/>"
    . "<br><br><input type='submit' name='transtype' value='Delete customerio record'/>"
    . "</form>";

if ($input->{transtype}) {
    #Error checking
    code_exit_BO(_get_display_message("ERROR: Please provide client loginid"))       unless $input->{clientloginid};
    code_exit_BO(_get_display_message("ERROR: Please provide a dual control code"))  unless $input->{DCcode};
    code_exit_BO(_get_display_message("ERROR: You must check the verification box")) unless $input->{verification};

    my $dcc_error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{transtype}})->validate_client_anonymization_control_code($input->{DCcode}, $input->{clientloginid});
    code_exit_BO(_get_display_message("ERROR: " . $dcc_error->get_mesg())) if $dcc_error;

    if ($input->{transtype} eq 'Anonymize client') {
        #Start anonymization
        my $success = BOM::Platform::Event::Emitter::emit(
            'anonymize_client',
            {
                loginid => $loginid,
            });

        my $msg =
              Date::Utility->new->datetime . " "
            . $input->{transtype} . " for "
            . $input->{clientloginid}
            . " by clerk=$clerk (DCcode="
            . $input->{DCcode}
            . ") $ENV{REMOTE_ADDR}";
        BOM::User::AuditLog::log($msg, '', $clerk);

        $msg = 'Client anonymization ' . ($success ? 'was started successfully.' : 'failed to start.');
        code_exit_BO(_get_display_message($msg));
    }

    if ($input->{transtype} eq 'Delete customerio record') {
        # sending email consent as 0 delete record from customerio
        BOM::Platform::Event::Emitter::emit(
            'email_consent',
            {
                loginid       => $loginid,
                email_consent => 0
            });

        code_exit_BO(_get_display_message("Process to delete customerio initiated. Please verify by logging into customer.io portal."));
    }
}

sub _get_display_message {
    my $message = shift;
    return "<p><h2>$message</h2></p>";
}

sub _get_display_error_message {
    my $message = shift;
    return "<p><h2><font color=red>$message</font></h2></p>";
}

code_exit_BO();
