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
my $clerk  = BOM::Backoffice::Auth0::get_staffname();

if ($broker eq 'FOG') {
    $broker = request()->broker_code;
    if ($broker eq 'FOG') {
        code_exit_BO('NOT RELEVANT FOR BROKER CODE FOG');
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
print qq~
    <table cellpadding="0" cellspacing="5">
        <tr>
            <td><b>LoginID: </b></td>
            <td>
                <form action="~ . request()->url_for('backoffice/f_clientloginid_edit.cgi') . qq~" method="get">
                    <input type="text" size="15" name="loginID" placeholder="loginid" value="" data-lpignore="true" />
                    <input type="submit" value="EDIT CLIENT DETAILS" />
                    <input type="hidden" name="broker" value="$encoded_broker" />
                    <a href="~ . request()->url_for('backoffice/f_popupclientsearch.cgi') . qq~">[Search]</a>
                    <a href="javascript:WinPopupSearchClients();">[OldSearch]</a>
                </form>
            </td>
        </tr>
        <tr>
            <td><b>Email: </b></td>
            <td>
                <form action="~ . request()->url_for('backoffice/client_email.cgi') . qq~" method="get">
                    <input type="text" size="30" name="email" placeholder="email\@domain.com" value="" data-lpignore="true" />
                    <input type="submit" value="View / Edit" />
                </form>
            </td>
        </tr>
    </table>
~;

Bar("IMPERSONATE CLIENT");
print '<form action="' . request()->url_for('backoffice/client_impersonate.cgi') . '" method="get">';
print '<b>Enter client loginid: </b>';
print '<input type=text size=15 name="impersonate_loginid" data-lpignore="true" /> ';
print "<input type='hidden' name='broker' value='$encoded_broker'>";
print '<input type="submit" value="Impersonate"></b></form>';

Bar("SEND ACCOUNT RECOVERY EMAIL");
BOM::Backoffice::Request::template()->process(
    'backoffice/newpassword_email.html.tt',
    {
        languages => BOM::Backoffice::Utility::get_languages(),
    }) || die BOM::Backoffice::Request::template()->error();

Bar("MAKE DUAL CONTROL CODE");
print
    "To update client details we require 2 staff members to authorise. One staff member needs to generate a 'Dual Control Code' that is then used by the other staff member when updating the details.<br><br>";
print "<form id='clientdetailsDCC' action='"
    . request()->url_for('backoffice/f_makeclientdcc.cgi')
    . "' method='get' class='bo_ajax_form'>"
    . "<input type='hidden' name='broker' value='$encoded_broker'>"
    . "<input type='hidden' name='l' value='EN'>"
    . " Type of transaction: <select name='transtype'>"
    . "<option value='UPDATECLIENTDETAILS'>Update client details</option>"
    . "</select>"
    . " Loginid: <input type='text' name='clientloginid' size='15' placeholder='required' data-lpignore='true' />"
    . "<br><br>Email of the client, enter new email if you want to change email address: <input type='text' name='clientemail' placeholder='required' data-lpignore='true' />"
    . "<br><br>Input a comment/reminder about this DCC: <input type='text' size='50' name='reminder' data-lpignore='true' />"
    . "<br><br><input type='submit' value='Make Dual Control Code (by "
    . encode_entities($clerk) . ")'>"
    . "</form>";

Bar("CLOSED/DISABLED ACCOUNTS");
my $client_login      = request()->param('login_id') // '';
my $show_notification = request()->param('editlink') and $client_login and request()->param('untrusted_action_type');

BOM::Backoffice::Request::template()->process(
    'backoffice/account/untrusted_form.html.tt',
    {
        selected_untrusted_action => request()->param('untrusted_action_type'),
        edit_url                  => request()->url_for('backoffice/untrusted_client_edit.cgi'),
        reasons                   => get_untrusted_client_reason(),
        broker                    => $broker,
        encoded_broker            => $encoded_broker,
        clientid                  => $client_login,
        actions                   => get_untrusted_types(),
        show_untrusted            => 1,
        show_login                => 1,
        show_notification         => $show_notification,
    }) || die BOM::Backoffice::Request::template()->error();

Bar("Set Aml Risk Classification - Multiple loginids");
BOM::Backoffice::Request::template()->process(
    'backoffice/account/bulk_aml_risk_form.html.tt',
    {
        selected_aml_risk_level => request()->param('aml_risk_level'),
        edit_url                => request()->url_for('backoffice/bulk_aml_risk.cgi'),
        loginids                => request()->param('risk_loginids') // '',
        aml_risk_levels         => [get_aml_risk_classicications()],
        disabled                => not BOM::Backoffice::Auth0::has_authorisation(['Compliance']),
    }) || die BOM::Backoffice::Request::template()->error();

# Monitor client lists
Bar("Monitor client lists");

print "Kindly select status to monitor clients on.";

my $untrusted_status = get_untrusted_types_hashref();

print "<br /><br /><form action=\""
    . request()->url_for('backoffice/f_viewclientsubset.cgi')
    . "\" method=get>"
    . "<input type=hidden name=broker value=$encoded_broker>"
    . "Select list : <select name=show>"
    . "<option value='age_verification'>Age Verified</option>"
    . "<option value='closed'>Closed Accounts</option>"
    . join('',
    map { "<option value='$_'> $untrusted_status->{$_}->{comments} </option>" }
        qw /disabled cashier_locked withdrawal_locked unwelcome no_trading no_withdrawal_or_trading/)
    . "</select>"
    . '<br /><input type=checkbox value="1" name="onlyfunded" id="chk_onlyfunded" /><label for="chk_onlyfunded">Only funded accounts</label> '
    . '<br /><input type=checkbox value="1" name="onlynonzerobalance" id="chk_onlynonzerobalance" /><label for="chk_onlynonzerobalance">Only nonzero balance</label> '
    . "<br /><input type=submit value='Monitor Clients on this list'>"
    . "</form>";

Bar('Client complete audit log');
print 'View client sequential combined activity<br/><br/>';

print "<form action=\"" . request()->url_for('backoffice/f_client_combined_audit.cgi') . "\" method=get>";
print qq~
    <table>
        <tr>
            <td>
            <b>Loginid</b>
            </td>
            <td>
            <input type=text size=15 name="loginid" value="" data-lpignore="true" />
            </td>
        </tr>
        <tr>
            <td>
            <b>From</b>
            </td>
            <td>
~;
print "<input name=startdate type=text data-lpignore='true' size=10 value='"
    . Date::Utility->today()->minus_time_interval('30d')->date
    . "'/></td></tr>";
print "<tr><td><b>To</b></td><td>";
print "<input name=enddate type=text data-lpignore='true' size=10 value='" . Date::Utility->today()->date . "'/></td></tr>";
print "</table>";
print "<input type=\"submit\" value=\"Submit\">";
print "</form>";

code_exit_BO();
