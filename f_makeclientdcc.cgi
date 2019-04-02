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

Bar("Make dual control code");

my $now   = Date::Utility->new;
my $input = request()->params;

$input->{'reminder'} = defang($input->{'reminder'});

if (length $input->{'reminder'} < 4) {
    print "ERROR: your comment/reminder field is too short! (need 4 or more chars)";
    code_exit_BO();
}

unless ($input->{clientemail}) {
    print "Please provide email";
    code_exit_BO();
}
unless ($input->{clientloginid}) {
    print "Please provide client loginid";
    code_exit_BO();
}

my $client = BOM::User::Client::get_instance({
    'loginid'    => uc($input->{'clientloginid'}),
    db_operation => 'replica'
});
if (not $client) {
    print "ERROR: " . encode_entities($input->{'clientloginid'}) . " does not exist! Perhaps you made a typo?";
    code_exit_BO();
}

if ($input->{'transtype'} =~ /^UPDATECLIENT/) {
    my $code = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{'transtype'}})->client_control_code($input->{'clientemail'}, $client->binary_user_id);

    my $message =
          "The dual control code created by $clerk  (for a "
        . $input->{'transtype'}
        . ") for "
        . $input->{'clientemail'}
        . " is: $code This code is valid for 1 hour (from "
        . $now->datetime_ddmmmyy_hhmmss
        . ") only. Reminder/comment: "
        . $input->{'reminder'};

    BOM::User::AuditLog::log($message, '', $clerk);

    print '<p>'
        . 'DCC: <br>'
        . '<textarea rows="5" cols="100" readonly="readonly">'
        . encode_entities($code)
        . '</textarea><br>'
        . 'This code is valid for 1 hour from now: UTC '
        . Date::Utility->new->datetime_ddmmmyy_hhmmss . '<br>'
        . 'Creator: '
        . $clerk . '<br>'
        . 'Email: '
        . $input->{clientemail} . '<br>'
        . 'Comment/reminder: '
        . $input->{reminder} . '</p>';

    print "<p>Note: "
        . encode_entities($input->{'clientloginid'}) . " is "
        . encode_entities($client->salutation) . ' '
        . encode_entities($client->first_name) . ' '
        . encode_entities($client->last_name)
        . ' current email is '
        . encode_entities($client->email);
} else {
    print "Transaction type is not valid";
}

code_exit_BO();
