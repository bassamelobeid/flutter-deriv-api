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
    code_exit_BO(
        "We cannot process your request because it would seem that your browser is not configured to accept cookies. Please check that the 'enable cookies' function is set if your browser, then please try again."
    );
}

my $today = Date::Utility->new->date_ddmmmyy;

Bar("Quick check of a client account");

print "<form action=\"" . request()->url_for('backoffice/f_manager_history.cgi') . "\" method=\"post\" class=\"row\">";
print "<label>Check Statement of Login ID:</label><input name='loginID' type=text size=15 value='' data-lpignore='true' /> ";
print "<input type='hidden' name=\"broker\" value=\"$encoded_broker\">";
print "<input type='hidden' name=\"l\" value=\"EN\">";
print "<input type='submit' class='btn btn--primary' value='Go'/>";
print "</form>";

#note : can only be used once in this script !!
print "<form action='" . request()->url_for('backoffice/f_manager_statement.cgi') . "' method='post' class='row'>";
print "<label>Check Portfolio of Login ID:</label><input name=loginID type=text size=15 value='' data-lpignore='true' /> ";
print "<input type=hidden name=outputtype value=table>";
print "<input type=hidden name=\"broker\" value=\"$encoded_broker\">";
print "<input type=hidden name=\"l\" value=\"EN\">";
print "<input type=\"submit\" class='btn btn--primary' value=\"Go\">";
print "</form>";

Bar("Make Dual Control Code");
print "<p>To comply with ISO17799 requirements, deposits/withdrawals to client accounts require 2 staff members to authorise.
One staff member needs to generate a 'Dual Control Code' that is then used by the other staff member when inputting the transaction.</p>";
print "<form id=\"paymentDCC\" action=\""
    . request()->url_for('backoffice/f_makedcc.cgi')
    . "\" method=\"post\" class=\"bo_ajax_form\">"
    . "<input type=\"hidden\" name=\"broker\" value=\"$encoded_broker\">"
    . "<input type=\"hidden\" name=\"l\" value=\"EN\">"
    . "<div class=\"row\">"
    . "<label>Amount:</label><select name=\"currency\">$currency_options</select> <input type=\"text\" name=\"amount\" size=\"7\" data-lpignore=\"true\" />"
    . "<label>Type of transaction:</label><select name=\"transtype\">"
    . "<option value=\"CREDIT\">CREDIT (deposit)</option>"
    . "<option value=\"DEBIT\">DEBIT (withdrawal)</option>"
    . "<option value=\"TRANSFER\">TRANSFER</option>"
    . "</select>"
    . "<label>Login ID of the client:</label><input type=\"text\" size=\"12\" name=\"clientloginid\" data-lpignore=\"true\" />"
    . "</div>"
    . "<div class=\"row\"><label>Input a comment/reminder about this DCC:</label><input type=\"text\" size=\"50\" name=\"reminder\" data-lpignore=\"true\" /></div>"
    . "<input type=\"submit\" class='btn btn--primary' value='Make Dual Control Code (by "
    . encode_entities($clerk) . ")'>"
    . "</form>";

my $tt = BOM::Backoffice::Request::template;

Bar("Manual payments");

$tt->process(
    'backoffice/account/manager_payments.tt',
    {
        languages        => BOM::Backoffice::Utility::get_languages(),
        currency_options => $currency_options,
    }) || die $tt->error();

Bar("Transfer between accounts");

$tt->process(
    'backoffice/account/manager_transfer.tt',
    {
        currency_options => $currency_options,
    }) || die $tt->error();

Bar("BATCH CREDIT/DEBIT CLIENTS ACCOUNT");

$tt->process('backoffice/account/manager_batch_generic.tt') || die $tt->error();

Bar("BATCH CREDIT/DEBIT CLIENTS ACCOUNT: DOUGHFLOW");

$tt->process('backoffice/account/manager_batch_doughflow.tt') || die $tt->error();

# RESCIND FREE GIFT
Bar("RESCIND FREE GIFTS");

print "<p>If an account is opened, gets a free gift, but never trades for XX days, then rescind the free gift.";
print "&nbsp;<span class='error'>DO NOT RUN THIS FOR MLT DUE TO LGA REQUIREMENTS</span></p>";

print "<form action=\""
    . request()->url_for('backoffice/f_rescind_freegift.cgi')
    . "\" method=post>"
    . "<input type=hidden name=broker value=$encoded_broker>"
    . "<div class='row'><label>Days of inactivity:</label><input type=text size=8 name=inactivedays value=90 data-lpignore='true' /> "
    . "<label>Message:</label><input type=text size=50 name=message value='Rescind of free gift for cause of inactivity' data-lpignore='true' /> "
    . "</div><select name=whattodo><option>Simulate<option>Do it for real !</select>"
    . "<input type=submit class='btn btn--primary' value='Rescind free gifts'>"
    . "</form>";

Bar("CLEAN UP GIVEN LIST OF ACCOUNTS");

print "<p>Paste here a list of accounts to rescind all their cash balances (separate with commas):</p>";

print "<form action=\""
    . request()->url_for('backoffice/f_rescind_listofaccounts.cgi')
    . "\" method=post>"
    . "<input type=hidden name=broker value=$encoded_broker>"
    . "<div class='row'><label>List of accounts:</label><input type=text size=60 name=listaccounts value='CBET1020,CBET1021' data-lpignore='true' /> (separate with commas)</div>"
    . "<div class='row'><label>Message:</label><input type=text size=65 name=message value='Account closed.' data-lpignore='true' /></div>"
    . "<div class='row'><select name=whattodo><option>Simulate<option>Do it for real !</select>"
    . " <input type=submit class='btn btn--primary' value='Rescind these accounts!'></div>"
    . "</form>";

Bar("Crypto cashier");

print '<a class="btn btn--primary" href="f_manager_crypto.cgi">Go to crypto cashier management page</a>';

code_exit_BO();
