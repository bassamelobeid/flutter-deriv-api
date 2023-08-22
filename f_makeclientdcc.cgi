#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use HTML::Entities;
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit      ();
use BOM::Backoffice::Cookie;
use BOM::User::AuditLog;
use BOM::DualControl;
BOM::Backoffice::Sysinit::init();
use Syntax::Keyword::Try;

use constant MAX_FILE_SIZE => 1024 * 1600;    # 1 MB size limit
use BOM::User::Client;
use CGI;
use Log::Any qw($log);

my $clerk = BOM::Backoffice::Auth0::get_staffname();
my ($code, $client_email, $client);
my $cgi   = CGI->new;
my $title = 'Make dual control code';
my $now   = Date::Utility->new;
my $input = request()->params;

unless ($input->{'transtype'} =~ /^UPDATECLIENT|Edit affiliates token|SELFTAGGING/) {
    code_exit_BO('please select a valid transaction type to update client details', $title);
}

if ($input->{'transtype'} eq "UPDATECLIENTDETAILS" && not($input->{client_loginid})) {
    code_exit_BO('Please provide client loginid.', $title);
} elsif ($input->{'transtype'} eq "UPDATECLIENT_DETAILS_BULK" && not($input->{'bulk_clientloginids'})) {
    code_exit_BO('ERROR: invalid file location or empty file!', $title);
}
my $batch_file = ref $input->{bulk_clientloginids} eq 'ARRAY' ? trim($input->{bulk_clientloginids}->[0]) : trim($input->{bulk_clientloginids});
my ($file, $csv, $lines);
if ($input->{'transtype'} =~ /^UPDATECLIENTDETAILS|Edit affiliates token/) {
    $client = eval { BOM::User::Client::get_instance({'loginid' => uc($input->{'client_loginid'}), db_operation => 'backoffice_replica'}) };
    code_exit_BO("ERROR: " . encode_entities($input->{'client_loginid'}) . " does not exist! Perhaps you made a typo?", $title) if not $client;
    $client_email = $client->email;
    $input->{'reminder'} = defang($input->{'reminder'});

    if ($input->{'transtype'} ne "Edit affiliates token") {
        if     (length $input->{'reminder'} < 4) { code_exit_BO('ERROR: your comment/reminder field is too short! (need 4 or more chars).', $title); }
        unless ($input->{client_email}) {
            code_exit_BO('Please provide email.', $title);
        }
        $client_email = lc $input->{client_email};
    }
    $code = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{'transtype'}})->client_control_code($client_email, $client->binary_user_id);

} elsif ($input->{'transtype'} eq "UPDATECLIENT_DETAILS_BULK") {

    code_exit_BO(_get_display_error_message("ERROR: $batch_file: only csv files allowed\n")) unless $batch_file =~ /(csv)$/i;
    code_exit_BO(_get_display_error_message("ERROR: " . encode_entities($batch_file) . " is too large.")) if $ENV{CONTENT_LENGTH} > MAX_FILE_SIZE;

    my ($bulk_upload);
    try {
        $file  = $cgi->upload('bulk_clientloginids');
        $csv   = Text::CSV->new();
        $lines = $csv->getline_all($file);
    } catch ($e) {
        code_exit_BO(_get_display_error_message("ERROR: " . $e)) if $e;
    }
    code_exit_BO(_get_display_error_message("ERROR: the number of client_ids exceeds limit of 2000 please reduce the number of entries"))
        if @$lines > 2000;
    $code = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{'transtype'}})->batch_status_update_control_code([map { join "\0" => $_->@* } $lines->@*]);

} elsif ($input->{'transtype'} eq "SELFTAGGING") {
    $code = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{'transtype'}})->self_tagging_control_code();
}

Bar($title);
if ($input->{'transtype'} eq "UPDATECLIENT_DETAILS_BULK") {
    my $message =
          "The dual control code created by $clerk  (for a "
        . $input->{'transtype'}
        . " is: $code This code is valid for 1 hour (from "
        . $now->datetime_ddmmmyy_hhmmss
        . ") only.";
    $message .= " Reminder/comment: " . $input->{'reminder'} if $input->{'reminder'};

    BOM::User::AuditLog::log($message, '', $clerk);

    print '<p>'
        . 'DCC: (single click to copy)<br>'
        . '<div class="dcc-code copy-on-click">'
        . encode_entities($code)
        . '</div><script>initCopyText()</script><br>'
        . 'This code is valid for 1 hour from now: UTC '
        . Date::Utility->new->datetime_ddmmmyy_hhmmss . '<br>'
        . 'Creator: '
        . $clerk . '<br>';
    print 'Comment/reminder: ' . $input->{reminder} . '</p>' if $input->{'reminder'};

} elsif ($input->{'transtype'} =~ /^UPDATECLIENT|Edit affiliates token/) {
    my $message =
          "The dual control code created by $clerk  (for a "
        . $input->{'transtype'}
        . ") for "
        . $client_email
        . " is: $code This code is valid for 1 hour (from "
        . $now->datetime_ddmmmyy_hhmmss
        . ") only.";
    $message .= " Reminder/comment: " . $input->{'reminder'} if $input->{'reminder'};

    BOM::User::AuditLog::log($message, '', $clerk);

    print '<p>'
        . 'DCC: (single click to copy)<br>'
        . '<div class="dcc-code copy-on-click">'
        . encode_entities($code)
        . '</div><script>initCopyText()</script><br>'
        . 'This code is valid for 1 hour from now: UTC '
        . Date::Utility->new->datetime_ddmmmyy_hhmmss . '<br>'
        . 'Creator: '
        . $clerk . '<br>'
        . 'Email: '
        . $client_email . '<br>';
    print 'Comment/reminder: ' . $input->{reminder} . '</p>' if $input->{'reminder'};

    print "<p>Note: "
        . encode_entities($input->{'client_loginid'}) . " is "
        . encode_entities($client->salutation) . ' '
        . encode_entities($client->first_name) . ' '
        . encode_entities($client->last_name)
        . ' current email is '
        . encode_entities($client_email);
} elsif ($input->{'transtype'} eq "SELFTAGGING") {
    my $message =
          "The dual control code created by $clerk  (for a "
        . $input->{'transtype'}
        . " )is: $code This code is valid for 1 hour (from "
        . $now->datetime_ddmmmyy_hhmmss
        . ") only.";
    $message .= " Reminder/comment: " . $input->{'reminder'} if $input->{'reminder'};

    BOM::User::AuditLog::log($message, '', $clerk);

    print '<p>'
        . 'DCC: (single click to copy)<br>'
        . '<div class="dcc-code copy-on-click">'
        . encode_entities($code)
        . '</div><script>initCopyText()</script><br>'
        . 'This code is valid for 1 hour from now: UTC '
        . Date::Utility->new->datetime_ddmmmyy_hhmmss . '<br>'
        . 'Creator: '
        . $clerk . '<br>';
    print 'Comment/reminder: ' . $input->{reminder} . '</p>' if $input->{'reminder'};

} else {
    print "Transaction type is not valid";
}

code_exit_BO();
