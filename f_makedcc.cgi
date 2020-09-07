#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use Format::Util::Strings qw( defang );
use Path::Tiny;
use HTML::Entities;

use BOM::User::Client;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::User::AuditLog;
use BOM::DualControl;
use BOM::Backoffice::Config;
use BOM::Backoffice::Cookie;
use LandingCompany::Registry;
BOM::Backoffice::Sysinit::init();

my $staff = BOM::Backoffice::Auth0::get_staffname();

my $title = 'Make dual control code';

my $now               = Date::Utility->new;
my $current_timestamp = $now->datetime_ddmmmyy_hhmmss;
my $input             = request()->params;

my ($client, $message);
if ($input->{'dcctype'} ne 'file_content') {

    unless ($input->{'amount'}) {
        code_exit_BO('ERROR: No amount was specified.', $title);
    }

    unless ($input->{'clientloginid'}) {
        code_exit_BO('ERROR: No LoginID for the client was specified.', $title);
    }

    # Regular expression for checking valid currency format depending on the type of currency.
    # Upto 2 decimal positions are allowed for fiat currencies and 8 for Cryptocurrencies.
    my $currency_regex =
        LandingCompany::Registry::get_currency_type($input->{'currency'}) eq 'fiat' ? qr/^(?:\d*\.\d{1,2}|\d+\.?)$/ : qr/^(?:\d*\.\d{1,8}|\d+\.?)$/;

    if ($input->{'amount'} !~ $currency_regex) {
        code_exit_BO('ERROR: Invalid amount: ' . $input->{'amount'}, $title);
    }

    $client = eval { BOM::User::Client::get_instance({'loginid' => uc($input->{'clientloginid'}), db_operation => 'replica'}) };

    if (not $client) {
        code_exit_BO('ERROR: ' . encode_entities($input->{'clientloginid'}) . ' does not exist! Perhaps you made a typo?', $title);
    }
}

my $code;
$input->{'reminder'} = defang($input->{'reminder'});

if (length $input->{'reminder'} < 4) {
    code_exit_BO('ERROR: your comment/reminder field is too short! (need 4 or more chars).', $title);
}

if ($input->{'dcctype'} eq 'file_content') {
    if (not -s $input->{'file_location'}) {
        code_exit_BO('ERROR: invalid file location or empty file!', $title);
    }

    Bar($title);

    my $file_location = $input->{'file_location'};
    my @lines         = Path::Tiny::path($file_location)->lines;

    $code = BOM::DualControl->new({
            staff           => $staff,
            transactiontype => $input->{'transtype'}})->batch_payment_control_code(scalar @lines);

    $message =
          "<b>The dual control code created by $staff for "
        . $input->{'purpose'}
        . " is: (single click to copy)</b>"
        . '<div class="dcc-code copy-on-click">'
        . encode_entities($code)
        . '</div><br>'
        . "This code is valid for 1 hour (from $current_timestamp) only.";

    print $message . '<script>initCopyText()</script>';

    $message =~ s/<[^>]*>/ /gs;
    BOM::User::AuditLog::log($message);

    # Logging
    Path::Tiny::path(BOM::Backoffice::Config::config()->{log}->{deposit})
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

    $message =
          "The dual control code created by $staff for an amount of "
        . $input->{'currency'}
        . $input->{'amount'}
        . " (for a "
        . $input->{'transtype'}
        . ") for "
        . $input->{'clientloginid'}
        . " is: $code This code is valid for 1 hour (from $current_timestamp) only.";

    BOM::User::AuditLog::log($message, '', $staff);

    Bar($title);

    print '<p>'
        . 'DCC: (single click to copy)<br>'
        . '<div class="dcc-code copy-on-click">'
        . encode_entities($code)
        . '</div><script>initCopyText()</script><br>'
        . 'This code is valid for 1 hour from now: UTC '
        . Date::Utility->new->datetime_ddmmmyy_hhmmss . '<br>'
        . 'Creator: '
        . $staff . '<br>'
        . 'Currency: '
        . $input->{currency} . '<br>'
        . 'Amount: '
        . $input->{amount} . '<br>'
        . 'Payment type: '
        . $input->{transtype} . '<br>'
        . 'Comment/reminder: '
        . $input->{reminder} . '</p>';

    print "<p>Note: "
        . encode_entities($input->{'clientloginid'}) . " is "
        . encode_entities($client->salutation) . ' '
        . encode_entities($client->first_name) . ' '
        . encode_entities($client->last_name);
    print "<br><b />PS: make sure you didn't get the currency wrong! You chose <font color=red>"
        . encode_entities($input->{'currency'})
        . "</font></b></p>";

    # Logging
    Path::Tiny::path(BOM::Backoffice::Config::config()->{log}->{deposit})
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
