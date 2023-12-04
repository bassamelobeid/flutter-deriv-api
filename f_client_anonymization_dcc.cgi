#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Date::Utility;
use CGI;
use Digest::SHA              qw(sha1_hex);
use Text::Trim               qw(trim);
use BOM::Backoffice::Request qw(request);

BOM::Backoffice::Sysinit::init();
use constant MAX_FILE_SIZE => 1024 * 1600;
my $input = request()->params;
my $clerk = BOM::Backoffice::Auth::get_staffname();
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
            transactiontype => $input->{'transtype'}})->batch_anonymization_control_code([map { join "\0" => $_->@* } $lines->@*]);
}
#Logging

my $message = "The dual control code created by $clerk  (for a " . $input->{transtype} . ") for " . $input->{clientloginid}
    // $input->{bulk_loginids} . " is: $code This code is valid for 1 hour (from " . Date::Utility->new->datetime_ddmmmyy_hhmmss . ") only.";

BOM::User::AuditLog::log($message, '', $clerk);

# Display
my $template_data = {
    dcc_code => encode_entities($code),
    utc_date => Date::Utility->new->datetime_ddmmmyy_hhmmss,
    clerk    => $clerk
};

if ($input->{clientloginid}) {
    $template_data->{client_login_id} = encode_entities($input->{clientloginid});
    $template_data->{salutation}      = encode_entities($client->salutation);
    $template_data->{first_name}      = encode_entities($client->first_name);
    $template_data->{last_name}       = encode_entities($client->last_name);
    $template_data->{email}           = encode_entities($client->email);
}

BOM::Backoffice::Request::template()->process('backoffice/f_client_anonymization_dcc.html.tt', $template_data)
    || die BOM::Backoffice::Request::template()->error(), "\n";

code_exit_BO();
