#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use HTML::Entities;
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Cookie;
use BOM::Platform::AuditLog;
use BOM::DualControl;
BOM::Backoffice::Sysinit::init();

use BOM::User::Client;

PrintContentType();
BrokerPresentation("MAKE DUAL CONTROL CODE");
my $clerk = BOM::Backoffice::Cookie::get_staff();

Bar("Make client dual control code");

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
            transactiontype => $input->{'transtype'}})->client_control_code($input->{'clientemail'});

    my $message =
          "The dual control code created by $clerk  (for a "
        . $input->{'transtype'}
        . ") for "
        . $input->{'clientemail'}
        . " is: $code This code is valid for 1 hour (from "
        . $now->datetime_ddmmmyy_hhmmss
        . ") only.";

    BOM::Platform::AuditLog::log($message, '', $clerk);

    print encode_entities($message);
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
