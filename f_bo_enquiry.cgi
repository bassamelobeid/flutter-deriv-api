#!/usr/bin/perl
package main;
use strict 'vars';

use f_brokerincludeall;
use Format::Util::Numbers qw(roundnear);
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('TRANSACTION REPORTS');

my $broker = request()->broker->code;
BOM::Backoffice::Auth0::can_access(['CS']);
my $currency_options = get_currency_options();

if ($broker eq 'FOG') {
    $broker = request()->broker->code;
}

if ($broker ne 'FOG') {
    # CLIENT ACCOUNTS
    Bar("VIEW CLIENT ACCOUNTS");

    # Client Portfolio
    print
        "<hr>Note : This function shows the client portfolio in exactly the same way as the client sees them on the client Website.  Therefore, in the Portfolio, 'Sale Prices' of contracts include the Company markup fee.<p>";
    print "<FORM ACTION=\"" . request()->url_for('backoffice/f_manager_statement.cgi') . "\" METHOD=\"POST\">";
    print "Check Portfolio of LoginID : <input id='portfolio_loginID' name=loginID type=text size=10 value='$broker'>";
    print "<input type=hidden name=outputtype value=table>";
    print "<INPUT type=hidden name=\"broker\" value=\"$broker\">";
    print "<INPUT type=hidden name=\"l\" value=\"EN\">";
    print "<INPUT type=\"submit\" value=\"Client Portfolio\">";
    print "</FORM>";

    # Client Credit/Debit Statement
    print build_client_statement_form($broker);

    print "<hr/><FORM ACTION=\"" . request()->url_for('backoffice/f_profit_table.cgi') . "\" METHOD=\"POST\">";
    print "Check Profit Table of LoginID : <input id='profit_check_loginID' name=loginID type=text size=10 value='$broker'>";
    print "From : <input name=startdate type=text size=10 value='" . Date::Utility->today()->minus_time_interval('30d')->date . "'/>";
    print "To : <input name=enddate type=text size=10 value='" . Date::Utility->today()->date . "'/>";
    print "<INPUT type=hidden name=\"broker\" value=\"$broker\">";
    print "<INPUT type=hidden name=\"l\" value=\"EN\">";
    print "<INPUT type=checkbox name=\"all\">All (No pagination) </INPUT>";
    print "<INPUT type=\"submit\" value=\"Client Profit Table\">";
    print "</FORM>";

    print "<hr/><FORM ACTION=\"" . request()->url_for('backoffice/f_profit_check.cgi') . "\" METHOD=\"POST\">";
    print "Check Profit of LoginID : <input id='profit_check_loginID' name=loginID type=text size=10 value='$broker'>";
    print "From : <input name=startdate type=text size=10 value='" . Date::Utility->today()->minus_time_interval('30d')->date . "'/>";
    print "To : <input name=enddate type=text size=10 value='" . Date::Utility->today()->date . "'/>";
    print "<INPUT type=hidden name=\"broker\" value=\"$broker\">";
    print "<INPUT type=hidden name=\"l\" value=\"EN\">";
    print "<INPUT type=\"submit\" value=\"Client Profit\">";
    print "</FORM>";

    # LIST CLIENT WITHDRAWAL LIMITS
    Bar("List client withdrawal limits");
    print
        "This function will let you view a client's payment history - i.e. how much he deposited by credit card, paypal, etc., and how much the system will let him withdraw in turn by each method.<P>";

    print "<form method=post action='" . request()->url_for('backoffice/c_listclientlimits.cgi') . "'>";
    print "LoginID : ";

    print "<input type=text size=15 name='login' onChange='CheckLoginIDformat(this)' value=''>";
    print " <a href=\"javascript:WinPopupSearchClients();\"><font class=smallfont>[Search]</font></a>";

    print "<INPUT type=hidden name=\"broker\" value=\"$broker\">";
    print "<input type=submit value='LIST CLIENT WITHDRAWAL LIMITS'>";
    print "</form>";

}

code_exit_BO();
