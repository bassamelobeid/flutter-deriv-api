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
<form action="~ . request()->url_for('backoffice/f_clientloginid_edit.cgi') . qq~" method="get" class="row">
    <label>Login ID:</label>
    <input type="text" size="15" name="loginID" placeholder="loginid" value="" data-lpignore="true" />
    <input type="submit" class="btn btn--primary" value="Edit client details" />
    <input type="hidden" name="broker" value="$encoded_broker" />
    <a href="~ . request()->url_for('backoffice/f_popupclientsearch.cgi') . qq~" class="btn btn--secondary">Search</a>
    <a href="javascript:WinPopupSearchClients();" class="btn btn--secondary">Old search</a>
</form>
<form action="~ . request()->url_for('backoffice/client_email.cgi') . qq~" method="get" class="row">
    <label>Email:</label>
    <input type="text" size="30" name="email" placeholder="email\@domain.com" value="" data-lpignore="true" />
    <input type="submit" class="btn btn--primary" value="View / Edit" />
</form>
~;

Bar("IMPERSONATE CLIENT");
BOM::Backoffice::Request::template()->process(
    'backoffice/client_impersonate_form.html.tt',
    {
        impersonate_url => request()->url_for('backoffice/client_impersonate.cgi'),
        encoded_broker  => $encoded_broker,
    });

Bar("SEND ACCOUNT RECOVERY EMAIL");
BOM::Backoffice::Request::template()->process('backoffice/newpassword_email.html.tt') || die BOM::Backoffice::Request::template()->error(), "\n";

Bar("MAKE DUAL CONTROL CODE");
print
    "<p>To update client details we require 2 staff members to authorise. One staff member needs to generate a 'Dual Control Code' that is then used by the other staff member when updating the details.</p>";
print "<form id='clientdetailsDCC' action='"
    . request()->url_for('backoffice/f_makeclientdcc.cgi')
    . "' method='get' class='bo_ajax_form'>"
    . "<input type='hidden' name='broker' value='$encoded_broker'>"
    . "<input type='hidden' name='l' value='EN'>"
    . "<div class='row'>"
    . "<label>Type of transaction:</label><select name='transtype'>"
    . "<option value='UPDATECLIENTDETAILS'>Update client details</option>"
    . "</select>"
    . "<label>Login ID:</label><input type='text' name='clientloginid' size='15' placeholder='required' data-lpignore='true' />"
    . "</div>"
    . "<div class='row'>"
    . "<label>Email of the client, enter new email if you want to change email address:</label><input type='text' name='clientemail' placeholder='required' data-lpignore='true' />"
    . "</div>"
    . "<div class='row'>"
    . "<label>Input a comment/reminder about this DCC:</label><input type='text' size='50' name='reminder' data-lpignore='true' />"
    . "</div>"
    . "<input type='submit' class='btn btn--primary' value='Make Dual Control Code (by "
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
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

Bar("Set Aml Risk Classification - Multiple loginids");
BOM::Backoffice::Request::template()->process(
    'backoffice/account/bulk_aml_risk_form.html.tt',
    {
        selected_aml_risk_level => request()->param('aml_risk_level'),
        edit_url                => request()->url_for('backoffice/bulk_aml_risk.cgi'),
        loginids                => request()->param('risk_loginids') // '',
        aml_risk_levels         => [get_aml_risk_classicications()],
        disabled                => not BOM::Backoffice::Auth0::has_authorisation(['Compliance']),
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

# Monitor client lists
Bar("Monitor client lists");

print "<p>Kindly select status to monitor clients on:</p>";

my $untrusted_status = get_untrusted_types_hashref();

print "<form action=\""
    . request()->url_for('backoffice/f_viewclientsubset.cgi')
    . "\" method=get>"
    . "<input type=hidden name=broker value=$encoded_broker>"
    . "<div class='row'><label>Status:</label><select name=show>"
    . "<option value='age_verification'>Age Verified</option>"
    . "<option value='closed'>Closed Accounts</option>"
    . join('',
    map { "<option value='$_'> $untrusted_status->{$_}->{comments} </option>" }
        qw /disabled cashier_locked withdrawal_locked unwelcome no_trading no_withdrawal_or_trading/)
    . "</select></div>"
    . '<div class="row"><input type=checkbox value="1" name="onlyfunded" id="chk_onlyfunded" /><label for="chk_onlyfunded">Only funded accounts</label></div>'
    . '<div class="row"><input type=checkbox value="1" name="onlynonzerobalance" id="chk_onlynonzerobalance" /><label for="chk_onlynonzerobalance">Only nonzero balance</label></div>'
    . "<input type=submit class='btn btn--primary' value='Monitor clients on this list'>"
    . "</form>";

Bar('Client complete audit log');
print '<h3>View client sequential combined activity</h3>';

print "<form action=\"" . request()->url_for('backoffice/f_client_combined_audit.cgi') . "\" method=get>";
print qq~
    <div class="row">
        <label>Login ID:</label>
        <input type=text size=15 name="loginid" value="" data-lpignore="true" />
        <label>From:</label>
        <input class="datepick" name=startdate type=text data-lpignore='true' size=10 value='~ . Date::Utility->today()->minus_time_interval('30d')->date . qq~'/>
        <label>To:</label>
        <input class="datepick" name=enddate type=text data-lpignore='true' size=10 value='~ . Date::Utility->today()->date . qq~'/>
    </div>
    ~;
print '<input type="submit" class="btn btn--primary" value="Submit">';
print "</form>";

code_exit_BO();
