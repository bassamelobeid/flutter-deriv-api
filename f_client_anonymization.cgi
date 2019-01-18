#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Date::Utility;

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation("CLIENT ANONYMIZATION");

my $input = request()->params;
my $clerk = BOM::Backoffice::Auth0::from_cookie()->{nickname};

Bar("MAKE DUAL CONTROL CODE");
print
    "To anonymize a client we require 2 staff members to authorise. One staff member needs to generate a 'Dual Control Code' that is then used by the other staff member when initiating the anonymization.<br><br>";
print "<form id='generateDCC' action='"
    . request()->url_for('backoffice/f_client_anonymization_dcc.cgi')
    . "' method='get' class='bo_ajax_form'>"
    . "<input type='hidden' name='l' value='EN'>"
    . "<input type='hidden' name='transtype' value='CLIENTANONYMIZE'>"
    . "Loginid : <input type='text' name='clientloginid' placeholder='required'>"
    . "<br><br><input type='submit' value='Make Dual Control Code (by "
    . encode_entities($clerk) . ")'>"
    . "</form>";

Bar("START ANONYMIZATION");
print "<b>WARNING : THIS WILL RESULT IN PERMANENT DATA LOSS</b><br><br>
    Anonymization will make the following changes:<br>
    <ul>
    <li>TBC : This functionality is not yet implemented</li>
    </ul>
    <hr>";
my $prev_loginid = $input->{clientloginid} // '';
my $prev_dcc     = $input->{DCcode}        // '';
print "<form id='generateDCC' action='"
    . request()->url_for('backoffice/f_client_anonymization.cgi')
    . "' method='post'>"
    . "<input type='hidden' name='l' value='EN'>"
    . "<input type='hidden' name='transtype' value='CLIENTANONYMIZE'>"
    . "Loginid : <input type='text' name='clientloginid' placeholder='required' value='"
    . $prev_loginid . "'>"
    . "<br><br>DCC : <input type='text' name='DCcode' placeholder='required' value='"
    . $prev_dcc . "'>"
    . "<br><br><input type='checkbox' name='verification' value='true'> I understand this action is irreversible"
    . "<br><br><input type='submit' value='Start (by "
    . encode_entities($clerk) . ")'>"
    . "</form>";

if ($input->{transtype} // '' eq 'CLIENTANONYMIZE') {
    #Error checking
    unless ($input->{clientloginid}) {
        print "ERROR: Please provide client loginid";
        code_exit_BO();
    }
    unless ($input->{DCcode}) {
        print "ERROR: Please provide a dual control code";
        code_exit_BO();
    }
    unless ($input->{verification}) {
        print "ERROR: You must check the verification box";
        code_exit_BO();
    }
    my $dcc_error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{transtype}})->validate_client_anonymization_control_code($input->{DCcode}, $input->{clientloginid});
    if ($dcc_error) {
        print "ERROR: " . $dcc_error->get_mesg();
        code_exit_BO();
    }

    #Start anonymization
    print "Anonymization successfully started (functionality not yet implemented).";

    my $msg =
          Date::Utility->new->datetime . " "
        . $input->{transtype} . " for "
        . $input->{clientloginid}
        . " by clerk=$clerk (DCcode="
        . $input->{DCcode}
        . ") $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, '', $clerk);
}

code_exit_BO();
