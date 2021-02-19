#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Date::Utility;
use CGI;
use Digest::SHA qw(sha1_hex);
use Text::Trim qw(trim);

BOM::Backoffice::Sysinit::init();
use constant MAX_FILE_SIZE => 1024 * 1600;
my $input = request()->params;
my $clerk = BOM::Backoffice::Auth0::get_staffname();
PrintContentType();
my $cgi = CGI->new;
Bar("Make dual control code");

my $batch_file = ref $input->{bulk_loginids} eq 'ARRAY' ? trim($input->{bulk_loginids}->[0]) : trim($input->{bulk_loginids});

my $loginid = trim uc($input->{clientloginid} // '');

# Error checks
code_exit_BO("Please provide a transaction type.") unless $input->{transtype};
code_exit_BO("Invalid transaction type")           unless ($input->{transtype} =~ /^Anonymize client|Delete customerio record/);
code_exit_BO(_get_display_error_message("ERROR: Please provide client loginid or batch file")) if (not $loginid and not $batch_file);
code_exit_BO(_get_display_error_message("ERROR: You cannot request for client and bulk anonymization at the same time. Please provide one of them."))
    if $loginid and $batch_file;

my ($code, $client);
if ($loginid) {
    my $well_formatted = check_client_login_id($loginid);
    code_exit_BO("Invalid Login ID provided!") unless $well_formatted;

    $client = eval { BOM::User::Client::get_instance({'loginid' => uc($loginid), db_operation => 'backoffice_replica'}) };
    code_exit_BO(_get_display_error_message("ERROR: " . encode_entities($input->{'clientloginid'}) . " does not exist")) unless $client;

    $code = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{transtype}})->client_anonymization_control_code($loginid);
}
if ($batch_file) {
    code_exit_BO(_get_display_error_message("ERROR: $batch_file: only csv files allowed\n")) unless $batch_file =~ /(csv)$/i;
    my $file = $cgi->upload('bulk_loginids');
    if ($ENV{CONTENT_LENGTH} > MAX_FILE_SIZE) {
        code_exit_BO(_get_display_error_message("ERROR: " . encode_entities($batch_file) . " is too large."));
    }
    my $csv   = Text::CSV->new();
    my $lines = $csv->getline_all($file);
    $code = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{'transtype'}})->batch_anonymization_control_code(sha1_hex(join q{} => map { join q{} => $_->@* } $lines->@*));
}
#Logging

my $message =
    "The dual control code created by $clerk  (for a " . $input->{transtype} . ") for " . $input->{clientloginid}
    // $input->{bulk_loginids} . " is: $code This code is valid for 1 hour (from " . Date::Utility->new->datetime_ddmmmyy_hhmmss . ") only.";

BOM::User::AuditLog::log($message, '', $clerk);

# Display

print '<p>'
    . 'DCC: (single click to copy)<br>'
    . '<div class="dcc-code copy-on-click">'
    . encode_entities($code)
    . '</div><script>initCopyText()</script><br>'
    . 'This code is valid for 1 hour from now: UTC '
    . Date::Utility->new->datetime_ddmmmyy_hhmmss . '<br>'
    . 'Creator: '
    . $clerk . '<br>' . '</p>';

print "<p>Note: "
    . encode_entities($input->{clientloginid}) . " is "
    . encode_entities($client->salutation) . ' '
    . encode_entities($client->first_name) . ' '
    . encode_entities($client->last_name)
    . ' current email is '
    . encode_entities($client->email)
    if $input->{clientloginid};

code_exit_BO();
