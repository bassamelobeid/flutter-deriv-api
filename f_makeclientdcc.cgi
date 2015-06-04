#!/usr/bin/perl
package main;
use strict 'vars';

use Path::Tiny;

use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use BOM::System::AuditLog;
use BOM::DualControl;
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("MAKE DUAL CONTROL CODE");
BOM::Platform::Auth0::can_access(['CS']);
my $clerk = BOM::Platform::Context::request()->bo_cookie->clerk;

Bar("Make client dual control code");

my $now   = Date::Utility->new;
my $today = $now->date_ddmmmyy;
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

my $client = BOM::Platform::Client::get_instance({'loginid' => uc($input->{'clientloginid'})});
if (not $client) {
    print "ERROR: " . $input->{'clientloginid'} . " does not exist! Perhaps you made a typo?";
    code_exit_BO();
}

if ($input->{'transtype'} =~ /^UPDATECLIENT/) {
    my $code = BOM::DualControl->new({
        staff           => $clerk,
        transactiontype => $input->{'transtype'}})->client_control_code($input->{'clientemail'});

    print "<p class=\"success_message\">The dual control code created by $clerk  (for a "
        . $input->{'transtype'}
        . ") for "
        . $input->{'clientemail'}
        . " is: <font size=+1><b>$code</b></font><br />This code is valid for today ($today) only.</p>";

    print "<p>Note: " . $input->{'clientloginid'} . " is " . $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name . ' current email is ' . $client->email;

    # Logging
    Path::Tiny::path("/var/log/fixedodds/fclientdetailsupdate.log")
        ->append($now->datetime
            . "GMT $clerk MAKES DUAL CONTROL CODE FOR "
            . $input->{'transtype'}
            . " email="
            . $input->{'clientemail'}
            . " loginid="
            . $input->{'clientloginid'}
            . " $ENV{'REMOTE_ADDR'} REMINDER="
            . $input->{'reminder'});
} else {
    print "Transaction type is not valid";
}

code_exit_BO();
