#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Date::Utility;
use CGI;
use Digest::SHA qw(sha1_hex);
use Text::Trim  qw(trim);

BOM::Backoffice::Sysinit::init();
use constant MAX_FILE_SIZE => 1024 * 1600;
my $input = request()->params;
my $clerk = BOM::Backoffice::Auth::get_staffname();
PrintContentType();
my $cgi = CGI->new;
Bar("Make dual control code");

# Error checks
code_exit_BO("Please provide a transaction type.") unless $input->{transtype};
code_exit_BO("Invalid transaction type")           unless ($input->{transtype} =~ /^Payments Settings/);

my $code = BOM::DualControl->new({
        staff           => $clerk,
        transactiontype => $input->{transtype}})->payments_settings_code();

my $message =
      "The dual control code created by $clerk  (for a "
    . $input->{transtype}
    . ") is: $code This code is valid for 1 hour (from "
    . Date::Utility->new->datetime_ddmmmyy_hhmmss
    . ") only.";

BOM::User::AuditLog::log($message, '', $clerk);

print '<p>'
    . 'DCC: (single click to copy)<br>'
    . '<div class="dcc-code copy-on-click">'
    . encode_entities($code)
    . '</div><script>initCopyText()</script><br>'
    . 'This code is valid for 1 hour from now: UTC '
    . Date::Utility->new->datetime_ddmmmyy_hhmmss . '<br>'
    . 'Creator: '
    . $clerk . '<br>' . '</p>';

code_exit_BO();
