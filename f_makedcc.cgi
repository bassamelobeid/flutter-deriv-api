#!/usr/bin/perl
package main;
use strict 'vars';

use Format::Util::Strings qw( defang );
use f_brokerincludeall;
use Path::Tiny;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use BOM::System::AuditLog;
use BOM::DualControl;
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("MAKE DUAL CONTROL CODE");
BOM::Platform::Auth0::can_access(['Payments']);
my $clerk = BOM::Platform::Context::request()->bo_cookie->clerk;

Bar("Make dual control code");

my $now   = Date::Utility->new;
my $today = $now->date_ddmmmyy;
my $input = request()->params;

my $client;
if ($input->{'dcctype'} ne 'file_content') {
    $client = BOM::Platform::Client::get_instance({'loginid' => uc($input->{'clientloginid'})});

    if (not $client) {
        print "ERROR: " . $input->{'clientloginid'} . " does not exist! Perhaps you made a typo?";
        code_exit_BO();
    }

    if ($input->{'dcctype'} ne 'cs') {
        if ($input->{'amount'} =~ /^\d\d?\,\d\d\d\.?\d?\d?$/) {
            $input->{'amount'} =~ s/\,//;
        }
        if ($input->{'amount'} !~ /^\d*\.?\d*$/) {
            print "ERROR in amount: " . $input->{'amount'};
            code_exit_BO();
        }
    }
}

my $code;
$input->{'reminder'} = defang($input->{'reminder'});

if (length $input->{'reminder'} < 4) {
    print "ERROR: your comment/reminder field is too short! (need 4 or more chars)";
    code_exit_BO();
}

if ($input->{'dcctype'} eq 'file_content') {
    if (not -s $input->{'file_location'}) {
        print "ERROR: invalid file location or empty file!";
        code_exit_BO();
    }

    my $file_location = $input->{'file_location'};
    my $path          = Path::Tiny::path($file_location);
    my @lines         = $path->lines;
    my $lines         = join("\n", @lines);
    $code = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{'transtype'}})->batch_payment_control_code($path->basename);

    print "The dual control code created by $clerk for "
        . $input->{'purpose'}
        . " is: <font size=+1><b>$code</b></font><br />This code is valid for today ($today) only.";

    # Logging
    Path::Tiny::path("/var/log/fixedodds/fmanagerconfodeposit.log")
        ->append($now->datetime
            . "GMT $clerk MAKES DUAL CONTROL CODE FOR "
            . $input->{'transtype'}
            . " AMOUNT="
            . $input->{'currency'}
            . $input->{'amount'}
            . " loginID="
            . $input->{'clientloginid'}
            . " $ENV{'REMOTE_ADDR'} REMINDER="
            . $input->{'reminder'});
} else {
    $code = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{'transtype'}})->payment_control_code($input->{'clientloginid'}, $input->{'currency'}, $input->{'amount'});

    print "<p class=\"success_message\">The dual control code created by $clerk for an amount of "
        . $input->{'currency'}
        . $input->{'amount'}
        . " (for a "
        . $input->{'transtype'}
        . ") for "
        . $input->{'clientloginid'}
        . " is: <font size=+1><b>$code</b></font><br />This code is valid for today ($today) only.</p>";

    print "<p>Note: " . $input->{'clientloginid'} . " is " . $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
    print "<br><b />PS: make sure you didn't get the currency wrong! You chose <font color=red>" . $input->{'currency'} . "</font></b></p>";

    # Logging
    Path::Tiny::path("/var/log/fixedodds/fmanagerconfodeposit.log")
        ->append($now->datetime
            . "GMT $clerk MAKES DUAL CONTROL CODE FOR "
            . $input->{'transtype'}
            . " AMOUNT="
            . $input->{'currency'}
            . $input->{'amount'}
            . " loginID="
            . $input->{'clientloginid'}
            . " $ENV{'REMOTE_ADDR'} REMINDER="
            . $input->{'reminder'});
}

code_exit_BO();
