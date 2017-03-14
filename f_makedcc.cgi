#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Format::Util::Strings qw( defang );
use Path::Tiny;
use Cache::RedisDB;
use HTML::Entities;

use Client::Account;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Platform::AuditLog;
use BOM::DualControl;
use BOM::Backoffice::Config;
use BOM::Backoffice::Cookie;
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("MAKE DUAL CONTROL CODE");
BOM::Backoffice::Auth0::can_access(['Payments']);
my $staff = BOM::Backoffice::Cookie::get_staff();

Bar("Make dual control code");

my $now               = Date::Utility->new;
my $current_timestamp = $now->datetime_ddmmmyy_hhmmss;
my $input             = request()->params;

my ($client, $message);
if ($input->{'dcctype'} ne 'file_content') {
    $client = Client::Account::get_instance({'loginid' => uc($input->{'clientloginid'})});

    if (not $client) {
        print "ERROR: " . encode_entities($input->{'clientloginid'}) . " does not exist! Perhaps you made a typo?";
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
    my @lines         = Path::Tiny::path($file_location)->lines;
    my $lines         = join("\n", @lines);

    $code = BOM::DualControl->new({
            staff           => $staff,
            transactiontype => $input->{'transtype'}})->batch_payment_control_code(scalar @lines);

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    $message =
          "The dual control code created by $staff for "
        . $input->{'purpose'}
        . " is: $code This code is valid for 1 hour (from $current_timestamp) only.";

    print encode_entities($message);

    BOM::Platform::AuditLog::log($message);

    # Logging
    Path::Tiny::path(BOM::Backoffice::Config::config->{log}->{deposit})
        ->append_utf8($now->datetime
            . "GMT $staff MAKES DUAL CONTROL CODE FOR "
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
            staff           => $staff,
            transactiontype => $input->{'transtype'}})->payment_control_code($input->{'clientloginid'}, $input->{'currency'}, $input->{'amount'});

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    $message =
          "The dual control code created by $staff for an amount of "
        . $input->{'currency'}
        . $input->{'amount'}
        . " (for a "
        . $input->{'transtype'}
        . ") for "
        . $input->{'clientloginid'}
        . " is: $code This code is valid for 1 hour (from $current_timestamp) only.";

    BOM::Platform::AuditLog::log($message, '', $staff);

    print encode_entities($message);
    print "<p>Note: "
        . encode_entities($input->{'clientloginid'}) . " is "
        . encode_entities($client->salutation) . ' '
        . encode_entities($client->first_name) . ' '
        . encode_entities($client->last_name);
    print "<br><b />PS: make sure you didn't get the currency wrong! You chose <font color=red>"
        . encode_entities($input->{'currency'})
        . "</font></b></p>";

    # Logging
    Path::Tiny::path(BOM::Backoffice::Config::config->{log}->{deposit})
        ->append_utf8($now->datetime
            . "GMT $staff MAKES DUAL CONTROL CODE FOR "
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
