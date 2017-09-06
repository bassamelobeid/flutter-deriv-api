#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use open qw[ :encoding(UTF-8) ];
use Format::Util::Strings qw( set_selected_item );
use HTML::Entities;

use f_brokerincludeall;
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation("CLIENT LOGINID ADMIN");

my $broker = request()->broker_code;
my $clerk  = BOM::Backoffice::Auth0::from_cookie()->{nickname};

if ($broker eq 'FOG') {
    $broker = request()->broker_code;
    if ($broker eq 'FOG') {
        print "NOT RELEVANT FOR BROKER CODE FOG";
        code_exit_BO();
    }
}

my $encoded_broker = encode_entities($broker);
# Check staff authorization
my $now       = Date::Utility->new;
my $today     = $now->date_ddmmmyy;
my $last_week = Date::Utility->new($now->epoch - 7 * 24 * 60 * 60)->date_ddmmmyy;
my $last_year = Date::Utility->new($now->epoch - 365 * 24 * 60 * 60)->date_ddmmmyy;

# CLIENT DETAILS
Bar('CLIENT ACCOUNT DETAILS');

print '<table border=0 width=100% cellpadding=4><tr><td>';

# client details
print '<form action="'
    . request()->url_for('backoffice/f_clientloginid_edit.cgi')
    . '" method=post>'
    . '<font size=2>'
    . '<input type=hidden name=broker value='
    . $encoded_broker . '>'
    . '<table>'
    . '<tr><td><b>LoginID</b></td><td> : ';

print '<input type=text size=15 name="loginID" value="">'
    . ' <a href="'
    . request()->url_for('backoffice/f_popupclientsearch.cgi')
    . '"><font class=smallfont>[Search]</font></a>'
    . ' <a href="javascript:WinPopupSearchClients();"><font class=smallfont>[OldSearch]</font></a>'
    . '</td></tr>';

print '<tr><td>&nbsp;</td><td>' . '&nbsp;&nbsp;<input type="submit" value="EDIT CLIENT DETAILS"></td>' . '</tr>' . '</table>' . '</font>' . '</form>';

# issued new password
print '<hr><form class="bo_ajax_form" action="'
    . request()->url_for('backoffice/f_clientloginid_newpassword.cgi')
    . '" method=post>'
    . '<input type=hidden name=broker value='
    . $encoded_broker . '>'
    . '<b>LoginID : </b>';
print "<input type=text size=15 name='show' onChange='CheckLoginIDformat(this)' value=''>";
print '&nbsp;&nbsp;<input type="submit" value="Send Account recovery email to client\'s registered email address"></b>' . '</form>';
print '</td></tr></table>';

Bar("VIEW/EDIT CLIENT'S Email");
print '<form action="' . request()->url_for('backoffice/client_email.cgi') . '" method="post">' . '<b>Client\'s Email : </b>';
print '<input type=text size=30 name="email">';
print '&nbsp;&nbsp;<input type="submit" value="View / Edit"></b>' . '</form>';

Bar("IMPERSONATE CLIENT");
print '<form action="' . request()->url_for('backoffice/client_impersonate.cgi') . '" method="post">';
print '<b>Enter client loginid: </b>';
print '<input type=text size=30 name="impersonate_loginid"><br>';
print "<input type='hidden' name='broker' value='$encoded_broker'>";
print '<input type="submit" value="Impersonate"></b></form>';

Bar("MAKE DUAL CONTROL CODE");
print
    "To update client details we require 2 staff members to authorise. One staff member needs to generate a 'Dual Control Code' that is then used by the other staff member when updating the details.<br><br>";
print "<form id='clientdetailsDCC' action='"
    . request()->url_for('backoffice/f_makeclientdcc.cgi')
    . "' method='post' class='bo_ajax_form'>"
    . "<input type='hidden' name='broker' value='$encoded_broker'>"
    . "<input type='hidden' name='l' value='EN'>"
    . " Type of transaction: <select name='transtype'>"
    . "<option value='UPDATECLIENTDETAILS'>Update client details</option>"
    . "</select>"
    . "Loginid : <input type='text' name='clientloginid' placeholder='required'>"
    . "<br><br>New email of the client: <input type='text' name='clientemail' placeholder='required'>"
    . "<br><br>Input a comment/reminder about this DCC: <input type='text' size='50' name='reminder'>"
    . "<br><br><input type='submit' value='Make Dual Control Code (by "
    . encode_entities($clerk) . ")'>"
    . "</form>";

Bar("CLOSED/DISABLED ACCOUNTS");
my $client_login                 = request()->param('login_id') || $broker . '';
my $untrusted_disabled_action    = "Disabled/Closed Accounts";
my $untrusted_cashier_action     = "Cashier Lock Section";
my $untrusted_unwelcome_action   = "Unwelcome loginIDs";
my $untrusted_withdrawal_action  = "Withdrawal locked";
my $jp_activation_pending_action = "JP Activation Pending";
my $file_path                    = BOM::Platform::Runtime->instance->app_config->system->directory->db . "/f_broker/$broker/";

# if redirect from client details page
if (request()->param('editlink') and $client_login and request()->param('untrusted_action_type')) {
    print "<font color=blue>This line has already exist in <b>$encoded_broker."
        . request()->param('untrusted_action_type')
        . "</b> file. "
        . "<br />To change the reason, kindly select from the dropdown selection list below and click 'Go'.<br /><br /></font>";
}
BOM::Backoffice::Request::template->process(
    'backoffice/account/untrusted_form.html.tt',
    {
        selected_untrusted_action => request()->param('untrusted_action_type'),
        edit_url                  => request()->url_for('backoffice/untrusted_client_edit.cgi'),
        reasons                   => [get_untrusted_client_reason()],
        broker                    => $broker,
        clientid                  => $client_login,
        actions                   => get_untrusted_types(),
        show_login                => 1,
    }) || die BOM::Backoffice::Request::template->error();

# display log differences for untrusted client section
print "<hr><b>View changes to this untrusted client section.</b><br />"
    . "To view all the changes made to each status, kindly click on each of the link below : ";

print "<br /><br /><table border=\"1\" cellpadding=\"3\">" . "<tr>"
    . "<th>Untrusted section</th>"
    . "<th>Show the log changes</th>"
    . "<th>Description</th>" . "</tr>" . "<tr>"
    . "<td>$untrusted_disabled_action</td>" . "<td>"
    . '<a href="'
    . request()->url_for(
    'backoffice/show_audit_trail.cgi',
    {
        broker   => $broker,
        category => "client_status_disabled"
    })
    . '">Disabled logins</a>' . "</td>"
    . "<td>LoginIDs on this list will not be able to log into their accounts - the system will say 'wrong loginID or password'.</td>" . "</tr>"
    . "<tr>"
    . "<td>$untrusted_cashier_action</td>" . "<td>"
    . '<a href="'
    . request()->url_for(
    'backoffice/show_audit_trail.cgi',
    {
        broker   => $broker,
        category => "client_status_cashier_locked"
    })
    . '">Lock Cashier Logins</a>' . "</td>"
    . "<td>To prohibit a client from making any further deposits or withdrawals (i.e. to completely lock the cashier section), add the client to this list.</td>"
    . "</tr>" . "<tr>"
    . "<td>$untrusted_unwelcome_action</td>" . "<td>"
    . '<a href="'
    . request()->url_for(
    'backoffice/show_audit_trail.cgi',
    {
        broker   => $broker,
        category => "client_status_unwelcome"
    })
    . '">Unwelcome Logins</a>' . "</td>"
    . "<td>Clients on this list will be able to log into their accounts, but they will not be able to deposit extra money nor buy any new contracts. They will be able to withdraw money, and they will also be able to close out positions.</td>"
    . "</tr>" . "<tr>"
    . "<td>$untrusted_withdrawal_action</td>" . "<td>"
    . '<a href="'
    . request()->url_for(
    "backoffice/show_audit_trail.cgi",
    {
        broker   => $broker,
        category => "client_status_withdrawal_locked"
    })
    . '">Locked Withdrawals</a>' . "</td>"
    . "<td>Only withdrawals are disabled</td>" . "</tr>"
    . "</table><br />";

# view all disabled accounts details
print '<hr><b>To view all disabled accounts and their a/c details</b><br />'
    . "<form action=\""
    . request()->url_for('backoffice/f_viewclientsubset.cgi')
    . "\" method=\"post\">"
    . "<input type=\"hidden\" name=\"broker\" value=\"$encoded_broker\">"
    . "<input type=\"hidden\" name=\"show\" value=\"disabled\">"
    . '<br /><input type="checkbox" value="1" checked name="onlylarge"> Only those with more than $5 equity';

if (BOM::Backoffice::Auth0::has_authorisation(['Payments'])) {
    print '<br />Password if you want to debit cash balances of accounts with over
			<input size="6" name="recoverdays" value="180"> days inactivity:
			<input size="5" type="password" name="recoverfromfraudpassword">';
}

print '<br /><input type="submit" value="Monitor Disabled Accounts">' . '</form>';

# Monitor client lists
Bar("Monitor client lists");

print "Kindly select status to monitor clients on.";

print "<br /><br /><form action=\""
    . request()->url_for('backoffice/f_viewclientsubset.cgi')
    . "\" method=post>"
    . "<input type=hidden name=broker value=$encoded_broker>"
    . "Select list : <select name=show>"
    . "<option value='age_verification'>Age Verified</option>"
    . "<option value='disabled'>Disabled/Closed Accounts</option>"
    . "<option value='cashier_locked'>Cashier Lock Section</option>"
    . "<option value='withdrawal_locked'>Withdrawal Lock Section</option>"
    . "<option value='unwelcome'>Unwelcome loginIDs</option>"
    . "</select>"
    . '<br /><input type=checkbox value="1" name=onlyfunded>Only funded accounts'
    . '<br /><input type=checkbox value="1" name=onlynonzerobalance>Only nonzero balance'
    . "<br /><input type=submit value='Monitor Clients on this list'>"
    . "</form>";

Bar('Client complete audit log');
print 'View client sequential combined activity<br/><br/>';

print "<form action=\"" . request()->url_for('backoffice/f_client_combined_audit.cgi') . "\" method=post>";
print qq~
    <table>
        <tr>
            <td>
            <b>Loginid</b>
            </td>
            <td>
            <input type=text size=15 name="loginid" value="">
            </td>
        </tr>
        <tr>
            <td>
            <b>From</b>
            </td>
            <td>
~;
print "<input name=startdate type=text size=10 value='" . Date::Utility->today()->minus_time_interval('30d')->date . "'/></td></tr>";
print "<tr><td><b>To</b></td><td>";
print "<input name=enddate type=text size=10 value='" . Date::Utility->today()->date . "'/></td></tr>";
print "</table>";
print "<input type=\"submit\" value=\"Submit\">";
print "</form>";

Bar('Client Desk.com cases');
print "<form action=\"" . request()->url_for('backoffice/f_client_deskcom.cgi') . "\" method=post>";
print qq~
    <table>
        <tr>
            <td>
            <b>Loginid</b>
            </td>
            <td>
            <input type=text size=15 name="loginid_desk" value="">
            </td>
        </tr>
        <tr>
            <td>
            <b>Cases created on</b>
            </td>
            <td>
~;
print "<input name=created type=text size=10 value='today'/></td></tr>";
print '<tr><td colspan=2>Case created(Date range "today", "yesterday", "week", "month", "year") as desk.com accepts these parameters</td></tr>';
print "</table>";
print "<input type=\"submit\" value=\"Submit\">";
print "</form>";
code_exit_BO();
