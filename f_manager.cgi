#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use HTML::Entities;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Utility;
use f_brokerincludeall;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('BACKOFFICE ACCOUNTS');
my $broker           = request()->broker_code;
my $encoded_broker   = encode_entities($broker);
my $clerk            = BOM::Backoffice::Auth0::get_staffname();
my $currency_options = get_currency_options();

if (length($broker) < 2) {
    print
        "We cannot process your request because it would seem that your browser is not configured to accept cookies.  Please check that the 'enable cookies' function is set if your browser, then please try again.";
    code_exit_BO();
}
my $today = Date::Utility->new->date_ddmmmyy;

Bar("QUICK CHECK OF A CLIENT ACCOUNT");

print "<FORM ACTION=\"" . request()->url_for('backoffice/f_manager_history.cgi') . "\" METHOD=\"POST\"><font size=2 face=verdana><B>";
print "Check Statement of LoginID : <input name=loginID type=text size=10 value=''>";
print "<INPUT type=hidden name=\"broker\" value=\"$encoded_broker\">";
print "<INPUT type=hidden name=\"l\" value=\"EN\">";
print "<INPUT type=\"submit\" value=Go>";
print "</FORM>";

#note : can only be used once in this script !!
print "<FORM ACTION=\"" . request()->url_for('backoffice/f_manager_statement.cgi') . "\" METHOD=\"POST\">";
print "Check Portfolio of LoginID : <input name=loginID type=text size=10 value=''>";
print "<input type=hidden name=outputtype value=table>";
print "<INPUT type=hidden name=\"broker\" value=\"$encoded_broker\">";
print "<INPUT type=hidden name=\"l\" value=\"EN\">";
print "<INPUT type=\"submit\" value=\"Go\">";
print "</FORM>";

Bar("Make Dual Control Control Code");
print "To comply with ISO17799 requirements, deposits/withdrawals to client accounts require 2 staff members to authorise.
One staff member needs to generate a 'Dual Control Code' that is then used by the other staff member when inputting the transaction.";
print "<form id=\"paymentDCC\" action=\""
    . request()->url_for('backoffice/f_makedcc.cgi')
    . "\" method=\"post\" class=\"bo_ajax_form\">"
    . "<input type=\"hidden\" name=\"broker\" value=\"$encoded_broker\">"
    . "<input type=\"hidden\" name=\"l\" value=\"EN\">"
    . " Amount: <select name=\"currency\">$currency_options</select> <input type=\"text\" name=\"amount\" size=\"7\">"
    . " Type of transaction: <select name=\"transtype\">"
    . "<option value=\"CREDIT\">CREDIT (deposit)</option>"
    . "<option value=\"DEBIT\">DEBIT (withdrawal)</option>"
    . "<option value=\"TRANSFER\">TRANSFER</option>"
    . "</select>"
    . " LoginID of the client: <input type=\"text\" size=\"12\" name=\"clientloginid\">"
    . "<br>Input a comment/reminder about this DCC: <input type=\"text\" size=\"50\" name=\"reminder\">"
    . "<br><input type=\"submit\" value='Make Dual Control Code (by "
    . encode_entities($clerk) . ")'>"
    . "</form>";

my $tt = BOM::Backoffice::Request::template;

Bar("MANUAL PAYMENTS");

$tt->process('backoffice/account/manager_payments.tt', {languages => BOM::Backoffice::Utility::get_languages()}) || die $tt->error();

Bar("TRANSFER BETWEEN ACCOUNTS");

$tt->process('backoffice/account/manager_transfer.tt') || die $tt->error();

Bar("BATCH CREDIT/DEBIT CLIENTS ACCOUNT");

$tt->process('backoffice/account/manager_batch_generic.tt') || die $tt->error();

Bar("BATCH CREDIT/DEBIT CLIENTS ACCOUNT: DOUGHFLOW");

$tt->process('backoffice/account/manager_batch_doughflow.tt') || die $tt->error();

Bar("Crypto cashier");

print '<a href="f_manager_crypto.cgi">Go to crypto cashier management page</a>';

code_exit_BO();

