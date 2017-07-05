#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use HTML::Entities;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('BACKOFFICE ACCOUNTS');
my $broker           = request()->broker_code;
my $encoded_broker   = encode_entities($broker);
my $clerk            = BOM::Backoffice::Auth0::from_cookie()->{nickname};
my $staff            = BOM::Backoffice::Auth0::can_access(['Payments']);
my $currency_options = get_currency_options();

if (length($broker) < 2) {
    print
        "We cannot process your request because it would seem that your browser is not configured to accept cookies.  Please check that the 'enable cookies' function is set if your browser, then please try again.";
    code_exit_BO();
}
my $today = Date::Utility->new->date_ddmmmyy;

# SHOW CLIENT DOCS
if ((request()->param('whattodo') // '') eq 'showdocs') {
    my $loginid = uc(request()->param('loginID'));
    my $client = Client::Account->new({loginid => $loginid});
    Bar(encode_entities("SHOW CLIENT PAYMENT DOCS FOR $loginid " . $client->full_name));
    print "ID docs:";
    print show_client_id_docs($client, show_delete => 1);
    print "<hr>Payment docs:";
    print show_client_id_docs($client, folder => 'payments');
    code_exit_BO();
}

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

print "<FORM ACTION=\"" . request()->url_for('backoffice/f_manager.cgi') . "\" METHOD=\"POST\"><font size=2 face=verdana><B>";
print "Show uploaded payment supporting docs of LoginID : <input name=loginID type=text size=10 value=''>";
print "<INPUT type=hidden name=\"broker\" value=\"$encoded_broker\">";
print "<input type=hidden name=whattodo value=showdocs>";
print "<INPUT type=\"submit\" value=Go> <a href='"
    . request()->url_for('backoffice/download_document.cgi', {path => "/$broker/payments"})
    . "'>[view complete list]</a>";
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

$tt->process('backoffice/account/manager_payments.tt') || die $tt->error();

Bar("TRANSFER BETWEEN ACCOUNTS");

$tt->process('backoffice/account/manager_transfer.tt') || die $tt->error();

Bar("BATCH CREDIT/DEBIT CLIENTS ACCOUNT");

$tt->process('backoffice/account/manager_batch_generic.tt') || die $tt->error();

Bar("BATCH CREDIT/DEBIT CLIENTS ACCOUNT: DOUGHFLOW");

$tt->process('backoffice/account/manager_batch_doughflow.tt') || die $tt->error();

## CTC
Bar("Crypto Cashier");

print '<FORM ACTION="' . request()->url_for('backoffice/f_manager_crypto.cgi') . '" METHOD="POST">';
print '<INPUT type="hidden" name="broker" value="' . $encoded_broker . '">';
print '<input type="text" name="start_date" required class="datepick">';
print '<input type="text" name="end_date" required class="datepick">';
print '<select name="currency">' . '<option value="BTC">Bitcoin</option>' . '</select>';
print '<INPUT type="submit" value="Recon" name="view_action"/>';
print '</FORM>';

print '<br>';
print '<h3>Deposit</h3>';
print '<FORM ACTION="' . request()->url_for('backoffice/f_manager_crypto.cgi') . '" METHOD="POST">';
print '<INPUT type="hidden" name="broker" value="' . $encoded_broker . '">';
print '<INPUT type="hidden" name="view_type" value="pending">';
print '<select name="currency">' . '<option value="BTC">Bitcoin</option>' . '</select>';
print '<INPUT type="submit" value="Deposit Transactions" name="view_action"/>';
print '</FORM>';

print '<h3>Withdrawal</h3>';
print '<FORM ACTION="' . request()->url_for('backoffice/f_manager_crypto.cgi') . '" METHOD="POST">';
print '<INPUT type=hidden name="broker" value="' . $encoded_broker . '">';
print '<select name="currency">' . '<option value="BTC">Bitcoin</option>' . '</select>';
print '<INPUT type="submit" value="Withdrawal Transactions" name="view_action"/>';
print '</FORM>';

print '<h3>Tools</h3>';
print '<FORM ACTION="' . request()->url_for('backoffice/f_manager_crypto.cgi') . '" METHOD="POST">';
print '<INPUT type=hidden name="broker" value="' . $encoded_broker . '">';
print '<select name="currency">' . '<option value="BTC">Bitcoin</option>' . '</select>';
print '<select name="command">'
    . '<option value="listaccounts">List accounts</option>'
    . '<option value="listtransactions">List transactions</option>'
    . '<option value="listaddressgroupings">List address groupings</option>'
    . '</select>';
print '<INPUT type="submit" value="Run tool" name="view_action"/>';
print '</FORM>';

code_exit_BO();
