#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use HTML::Entities;
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Cookie;
use BOM::User::AuditLog;
use BOM::DualControl;
BOM::Backoffice::Sysinit::init();

use BOM::User::Client;

my $clerk = BOM::Backoffice::Auth0::get_staffname();

my $title = 'Make dual control code';

my $now   = Date::Utility->new;
my $input = request()->params;

unless ($input->{clientloginid}) {
    code_exit_BO('Please provide client loginid.', $title);
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => uc($input->{'clientloginid'}), db_operation => 'replica'}) };
if (not $client) {
    code_exit_BO("ERROR: " . encode_entities($input->{'clientloginid'}) . " does not exist! Perhaps you made a typo?", $title);
}
my $client_email = $client->email;

if ($input->{'transtype'} =~ /^UPDATECLIENT/) {
    $input->{'reminder'} = defang($input->{'reminder'});

    if (length $input->{'reminder'} < 4) {
        code_exit_BO('ERROR: your comment/reminder field is too short! (need 4 or more chars).', $title);
    }

    unless ($input->{clientemail}) {
        code_exit_BO('Please provide email.', $title);
    }
    $client_email = lc $input->{clientemail};
}

Bar($title);

if ($input->{'transtype'} =~ /^UPDATECLIENT|Edit affiliates token/) {
    my $code = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{'transtype'}})->client_control_code($client_email, $client->binary_user_id);

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
        . encode_entities($input->{'clientloginid'}) . " is "
        . encode_entities($client->salutation) . ' '
        . encode_entities($client->first_name) . ' '
        . encode_entities($client->last_name)
        . ' current email is '
        . encode_entities($client_email);
} else {
    print "Transaction type is not valid";
}

code_exit_BO();
