#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Date::Utility;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Platform::Event::Emitter;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Syntax::Keyword::Try;
use Digest::SHA qw(sha1_hex);

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation("CLIENT ANONYMIZATION");

my $input            = request()->params;
my $clerk            = BOM::Backoffice::Auth0::get_staffname();
my $cgi              = CGI->new;
my $transaction_type = $input->{transtype} // '';
Bar("MAKE DUAL CONTROL CODE");
print
    "To anonymize a client we require 2 staff members to authorize. One staff member needs to generate a 'Dual Control Code' that is then used by the other staff member when initiating the anonymization.<br><br>";
print "<form id='generateDCC' action='"
    . request()->url_for('backoffice/f_client_anonymization_dcc.cgi')
    . "' method='POST' class='bo_ajax_form' enctype='multipart/form-data'>"
    . "<input type='hidden' name='l' value='EN'>"
    . "<label>Transaction type:</label><select name='transtype'>"
    . "<option value='Anonymize client'>Anonymize client details</option>"
    . "</select><br><br>"
    . "<p><b>Provide Login ID for individual anonymization or attach a file for bulk anonymization:</b></p>"
    . "<label>Login ID:</label><input type='text' name='clientloginid' size='15' data-lpignore='true'>"
    . "<label>File:</label><input type='file' name='bulk_loginids'>"
    . "<br><br><input type='submit' class='btn btn--primary' value='Make Dual Control Code (by "
    . encode_entities($clerk) . ")'>"
    . "</form>";

Bar("START ANONYMIZATION");
print "<b class='error'>WARNING : THIS WILL RESULT IN PERMANENT DATA LOSS</b><br><br>
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
    <li>Remove user record from customer.io</li>
    </ul>
    <hr>";
my $loginid  = $input->{clientloginid} // '';
my $prev_dcc = $input->{DCcode}        // '';
print "<form id='clientAnonymization' action='"
    . request()->url_for('backoffice/f_client_anonymization.cgi')
    . "' method='post' enctype='multipart/form-data'>"
    . "<input type='hidden' name='l' value='EN'>"
    . "<p><b>Provide Login ID for individual anonymization or attach a file for bulk anonymization:</b></p>"
    . "<label>Login ID:</label><input type='text' name='clientloginid' size='15' placeholder='required' data-lpignore='true' value='"
    . $loginid . "'>"
    . "<br><br><label>File:</label><input type='file' name='bulk_anonymization'>"
    . "<br><br><label>DCC:</label><input type='text' name='DCcode' size='50' data-lpignore='true' value='"
    . $prev_dcc . "'>"
    . "<br><br><input type='checkbox' name='verification' id='chk_verify' value='true'> <label for='chk_verify'>I understand this action is irreversible ("
    . encode_entities($clerk)
    . ")</label><br><br><input type='submit' class='btn btn--primary' name='transtype' value='Anonymize client'/>"
    . "</form>";

if ($transaction_type eq 'Anonymize client') {
    #Error checking
    code_exit_BO(_get_display_error_message("ERROR: Please provide client loginid or loginids file"))
        if not $input->{clientloginid} and not $input->{bulk_anonymization};
    code_exit_BO(
        _get_display_error_message("ERROR: You can not request for client and bulk anonymization at the same time. Please provide one of them."))
        if $input->{clientloginid} and $input->{bulk_anonymization};
    code_exit_BO(_get_display_error_message("ERROR: Please provide a dual control code"))  unless $input->{DCcode};
    code_exit_BO(_get_display_error_message("ERROR: You must check the verification box")) unless $input->{verification};
    my ($file, $csv, $lines, $bulk_upload);
    if ($input->{clientloginid}) {
        my $dcc_error = BOM::DualControl->new({
                staff           => $clerk,
                transactiontype => $input->{transtype}})->validate_client_anonymization_control_code($input->{DCcode}, $loginid);
        code_exit_BO(_get_display_error_message("ERROR: " . $dcc_error->get_mesg())) if $dcc_error;
    }
    if ($bulk_upload = $input->{bulk_anonymization}) {
        try {
            $file  = $cgi->upload('bulk_anonymization');
            $csv   = Text::CSV->new();
            $lines = $csv->getline_all($file);
        } catch ($e) {
            code_exit_BO(_get_display_error_message("ERROR: " . $e)) if $e;
        }
        my $dcc_error = BOM::DualControl->new({
                staff           => $clerk,
                transactiontype => $input->{transtype}}
        )->validate_batch_anonymization_control_code($input->{DCcode}, sha1_hex(join q{} => map { join q{} => $_->@* } $lines->@*));
        code_exit_BO(_get_display_error_message("ERROR: " . $dcc_error->get_mesg())) if $dcc_error;
    }
    if ($input->{transtype} eq 'Anonymize client') {
        # Start anonymization for a client
        if ($loginid) {
            my $success = BOM::Platform::Event::Emitter::emit(
                'anonymize_client',
                {
                    loginid => $loginid,
                });
            my $msg = sprintf '%s %s for %s by clerk=%s (DCcode=%s) %s',
                Date::Utility->new->datetime,
                $input->{transtype},
                $input->{clientloginid},
                $clerk,
                $input->{DCcode},
                $ENV{REMOTE_ADDR};
            BOM::User::AuditLog::log($msg, '', $clerk);

            $msg = 'Client anonymization ' . ($success ? 'was started successfully.' : 'failed to start.');
            code_exit_BO(_get_display_message($msg), undef, $success);
        }
        # Start anonymization for a list of client
        if ($bulk_upload) {
            try {
                die "$bulk_upload: only csv files allowed\n" unless $bulk_upload =~ /\.csv$/i;

                BOM::Platform::Event::Emitter::emit('bulk_anonymization', {data => $lines});
                print '<p class="success">' . " $bulk_upload is being processed. An email will be sent to compliance when the job completes.</p>";
            } catch ($e) {
                print '<p class="error">ERROR: ' . $e . '</p>' if $e;
            }
        }
    }
}

sub _get_display_message {
    my $message = shift;
    return "<p class='success'>$message</p>";
}

sub _get_display_error_message {
    my $message = shift;
    return "<p class='error'>$message</p>";
}

code_exit_BO();
