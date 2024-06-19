#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Format::Util::Strings qw( defang );
use Path::Tiny;

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Config;
use BOM::User::AuditLog;
use BOM::DualControl;
use BOM::MT5::BOUtility;

use List::MoreUtils qw(uniq);

BOM::Backoffice::Sysinit::init();

my $staff = BOM::Backoffice::Auth::get_staffname();

my $title             = 'Make dual control code (MT5 Auto Transfer)';
my $now               = Date::Utility->new;
my $current_timestamp = $now->datetime_ddmmmyy_hhmmss;
my $input             = request()->params;

unless ($input->{mt5accountid}) {
    code_exit_BO('ERROR: No MT5 Account ID Entered.', $title);
}

my $input_mt5_accounts = $input->{mt5accountid};
$input_mt5_accounts =~ s/\s+//g;
my @mt5_accounts = split(',', uc($input_mt5_accounts || ''));

unless (@mt5_accounts) {
    print 'No MT5 Accounts Found! <br>';
    code_exit_BO();
}

$input->{reminder} = defang($input->{reminder});
if (length $input->{reminder} < 4) {
    code_exit_BO('ERROR: your comment/reminder field is too short! (need 4 or more chars).', $title);
}

@mt5_accounts = uniq(@mt5_accounts);
my @invalid_mt5 = @{BOM::MT5::BOUtility::valid_mt5_check(\@mt5_accounts)};

if (@invalid_mt5) {
    print 'DCC Halted: Incorrect MT5 Account Detected <br>' . join('', @invalid_mt5);
    code_exit_BO();
}

my $code = BOM::DualControl->new({
        staff           => $staff,
        transactiontype => 'TRANSFER'
    })->batch_payment_control_code(\@mt5_accounts);

my $message =
      "<b>The dual control code created by $staff for MT5 Auto Transfer"
    . " is: (single click to copy)</b>"
    . '<div class="dcc-code copy-on-click">'
    . encode_entities($code)
    . '</div><br>'
    . "This code is valid for 1 hour (from $current_timestamp) only.";

print $message . '<script>initCopyText()</script>';

$message =~ s/<[^>]*>/ /gs;
BOM::User::AuditLog::log($message);

Path::Tiny::path(BOM::Backoffice::Config::config()->{log}->{deposit})
    ->append_utf8($now->datetime
        . "GMT $staff MAKES DUAL CONTROL CODE FOR MT5 AUTO TRANSFER"
        . " FOR MT5 ACCOUNTS: "
        . join(', ', @mt5_accounts)
        . " $ENV{'REMOTE_ADDR'} REMINDER="
        . $input->{'reminder'});

code_exit_BO();

