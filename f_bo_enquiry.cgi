#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('TRANSACTION REPORTS');

my $broker = request()->broker_code;

if ($broker eq 'FOG') {
    $broker = request()->broker_code;
}

if ($broker ne 'FOG') {
    my $encoded_broker = encode_entities($broker);
    # CLIENT ACCOUNTS
    Bar("VIEW CLIENT ACCOUNTS");

    # Client Portfolio
    print
        "<p>Note : This function shows the client portfolio in exactly the same way as the client sees them on the client Website. Therefore, in the Portfolio, 'Sale Prices' of contracts include the Company markup fee.</p>";
    print "<FORM ACTION=\"" . request()->url_for('backoffice/f_manager_statement.cgi') . "\" METHOD=\"POST\">";
    print "Check Portfolio of LoginID: <input id='portfolio_loginID' name=loginID type=text size=15 value='$encoded_broker' data-lpignore='true' /> ";
    print "<input type=hidden name=outputtype value=table>";
    print "<INPUT type=hidden name=\"broker\" value=\"$encoded_broker\">";
    print "<INPUT type=hidden name=\"l\" value=\"EN\">";
    print "<INPUT type=\"submit\" value=\"Client Portfolio\">";
    print "</FORM>";

    # Client Credit/Debit Statement
    print build_client_statement_form($broker);

    print "<hr/><FORM ACTION=\""
        . request()->url_for('backoffice/f_profit_table.cgi')
        . "\" METHOD=\"POST\" onsubmit='return validate_month(\"profit_table\")' >";
    print
        "<span style=\"color:red;\"><b>Show All Transaction</b>, may fail for clients with huge number of transaction, so use this feature only when required.</span><br/>";
    print
        "Check Profit Table of LoginID: <input id='profit_check_loginID' name=loginID type=text size=15 value='$encoded_broker' data-lpignore='true' /> ";
    print "From: <input name='first_purchase_time' type='text' size='10' value='"
        . Date::Utility->today()->_minus_months(1)->date
        . "' required pattern='\\d{4}-\\d{2}-\\d{2}' class='datepick' id='profit_table_startdate' data-lpignore='true' /> ";
    print "To: <input name='last_purchase_time' type='text' size='10' value='"
        . Date::Utility->today()->date
        . "' required pattern='\\d{4}-\\d{2}-\\d{2}' class='datepick' id='profit_table_enddate' data-lpignore='true'/> ";
    print "<INPUT type=hidden name=\"broker\" value=\"$encoded_broker\">";
    print "<INPUT type=hidden name=\"l\" value=\"EN\">";
    print
        "<INPUT type=checkbox name=\"all_in_one_page\" id=\"all_in_one_page_profit\" /><label for=\"all_in_one_page_profit\">Show All Transactions</label> ";
    print "<INPUT type=\"submit\" value=\"Client Profit Table\">";
    print "</FORM>";

    print "<hr/><FORM ACTION=\""
        . request()->url_for('backoffice/f_profit_check.cgi')
        . "\" METHOD=\"POST\" onsubmit=\"return validate_month('profit')\">";
    print
        "Check Profit of LoginID : <input id='profit_check_loginID' name=loginID type=text size=15 value='$encoded_broker' data-lpignore='true' /> ";
    print "From: <input name=startdate type=text size=10 value='"
        . Date::Utility->today()->_minus_months(1)->date
        . "' required pattern='\\d{4}-\\d{2}-\\d{2}' class='datepick' id='profit_startdate' data-lpignore='true' /> ";
    print "To: <input name=enddate type=text size=10 value='"
        . Date::Utility->today()->date
        . "' required pattern='\\d{4}-\\d{2}-\\d{2}' class='datepick' id='profit_enddate' data-lpignore='true' /> ";
    print "<INPUT type=hidden name=\"broker\" value=\"$encoded_broker\">";
    print "<INPUT type=hidden name=\"l\" value=\"EN\">";
    print "<INPUT type=\"submit\" value=\"Client Profit\">";
    print "</FORM>";

    # LIST CLIENT WITHDRAWAL LIMITS
    Bar("List client withdrawal limits");
    print
        "This function will let you view a client's payment history - i.e. how much he deposited by credit card, paypal, etc., and how much the system will let him withdraw in turn by each method.<P>";

    print "<form method=post action='" . request()->url_for('backoffice/c_listclientlimits.cgi') . "'>";
    print "LoginID: ";

    print "<input type=text size=15 name='login' onChange='CheckLoginIDformat(this)' value='' data-lpignore='true' /> ";
    print " <a href=\"javascript:WinPopupSearchClients();\"><font class=smallfont>[Search]</font></a> ";

    print "<INPUT type=hidden name=\"broker\" value=\"$encoded_broker\">";
    print "<input type=submit value='LIST CLIENT WITHDRAWAL LIMITS'>";
    print "</form>";
    print q{
<script type="text/javascript" language="javascript">
function validate_month(name){
    var start_date;
    var end_date;
    if(name == 'statement'){
        start_date = $('#statement_startdate').val();
        end_date  = $('#statement_enddate').val();
    }
    else if(name == 'profit_table'){
       start_date = $('#profit_table_startdate').val();
       end_date = $('#profit_table_enddate').val();
    }
    else if(name == 'profit'){
       start_date = $('#profit_startdate').val();
       end_date = $('#profit_enddate').val();
    }
    start_date = new Date(start_date);
    end_date = new Date(end_date);
    if(start_date == 'Invalid Date' || end_date == 'Invalid Date') {
       alert('Wrong date entered');
       return false;
    }
    return true;
}

$(document).ready(function() {
      $('.datepick').datepicker({dateFormat: "yy-mm-dd"});
});
</script>
};

    Bar("Find Transaction By Ref. (ID)");
    print qq~
        <form method="post" action="~ . request()->url_for('backoffice/f_manager_history.cgi') . qq~">
            <label for="findtransid_loginid">LoginID: </label>
            <input type="text" name="loginID" id="findtransid_loginid" required size="15" data-lpignore="true" />

            <label for="findtransid_transid">Transaction Ref.: </label>
            <input type="number" name="transactionID" id="findtransid_transid" required data-lpignore="true" />

            <input type="submit" value="Find Transaction By Ref. (ID)" />
        </form>
    ~;
}

code_exit_BO();
