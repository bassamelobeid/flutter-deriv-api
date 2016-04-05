#!/usr/bin/perl
package main;

use strict 'vars';

use List::MoreUtils qw(any);
use DateTime;
use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Market::UnderlyingDB;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('ACCOUNTING REPORTS');
BOM::Backoffice::Auth0::can_access(['Accounts']);
my $broker           = request()->broker->code;
my $all_currencies   = request()->available_currencies;
my $currency_options = get_currency_options();
my $feedloc          = BOM::Platform::Runtime->instance->app_config->system->directory->feed;
my $dbloc            = BOM::Platform::Runtime->instance->app_config->system->directory->db;
my $tmp_dir          = BOM::Platform::Runtime->instance->app_config->system->directory->tmp;

my $now       = Date::Utility->new;
my $lastmonth = $now->months_ahead(-1);

# Daily Turnover Report
Bar("DAILY TURNOVER REPORT");

print "<form action=\"" . request()->url_for('backoffice/f_dailyturnoverreport.cgi') . "\" method=post>";
print "<input type=hidden name=broker value=$broker>";
print 'Month: <input type=text size=12 name=month value="' . $now->months_ahead(0) . '">';
print "<br /><input type=\"submit\" value=\"Daily Turnover Report\"> CLICK ONLY ONCE! Be patient if slow to respond.";
print "</form>";

# DAILY SUMMARY FILES
Bar("DailySummary files");

print "The DailySummary files are generated once a day, and are in CSV format.  You can import them into Excel.";

my $RECENTDAYS;
foreach my $currl (@{$all_currencies}) {
    my $fileext = ($currl eq 'USD') ? '' : ".$currl";

    for (my $i = 0; $i < 90; $i++) {
        my $day          = Date::Utility->new($now->epoch - 86400 * $i)->date_ddmmmyy;
        my $summary_file = "$dbloc/f_broker/$broker/dailysummary/$day.summary$fileext";
        if (-e $summary_file) {
            $RECENTDAYS .= "<OPTION value='$summary_file'>$day$fileext";
        }
    }

    #end of years
    for (my $year_number = 0; $year_number <= $now->year_in_two_digit; $year_number++) {
        my $year = sprintf '%02d', $year_number;
        my $summary_file = "$dbloc/f_broker/$broker/dailysummary/31-Dec-$year.summary$fileext";
        if (-e $summary_file) {
            $RECENTDAYS .= "<OPTION value='$summary_file'>31-Dec-$year$fileext";
        }

        $summary_file = "$dbloc/f_broker/$broker/dailysummary/1-Jan-$year.summary$fileext";
        if (-e $summary_file) {
            $RECENTDAYS .= "<OPTION value='$summary_file'>1-Jan-$year$fileext";
        }
    }
}

print "<form action=\""
    . request()->url_for('backoffice/f_show.cgi')
    . "\" method=\"get\">"
    . "<b>Reference date :</b> <select name=\"show\">$RECENTDAYS</select>"
    . "<input type=\"submit\" value=\"View Dailysummary File\">"
    . "</form>";

print "<form action=\""
    . request()->url_for('backoffice/f_formatdailysummary.cgi')
    . "\" method=\"get\">"
    . "Reference date : <select name=\"show\">$RECENTDAYS</select>"
    . "<input type=checkbox name=displayport value=yes>Display portfolio"
    . "<br />Output <input type=text size=6 value='30' name=outputlargest> largest clients only"
    . "<br />*or* view only these clients : <input type=text size=20 name=viewonlylist> (list loginIDs separated by spaces)"
    . "<input type=\"submit\" value=\"View Dailysummary File in Table format\">"
    . "</form>";

my $landing_company = BOM::Platform::Runtime->instance->broker_codes->landing_company_for($broker)->short;
if (any { $landing_company eq $_ } qw(iom malta maltainvest)) {
    Bar("HMCE/IOMCE bet numbering records");

    print "<form action=\""
        . request()->url_for('backoffice/f_broker_hmce_numbering_output.cgi')
        . "\" method=post>"
        . "<input type=hidden name=\"broker\" value=\"$broker\">"
        . "<input type=hidden name=\"output\" value=\"CSV\">"
        . "<br />Do : <select name=action_type>
                       <option>sell</option>
                       <option>buy</option>
               </select>"
        . "<br />Start Date : <input type=text size=10 name=start> eg: 2015-01-01"
        . "<br />End Date: <input type=text size=10 name=end> eg: 2015-01-31"
        . "<br /><b><input type=\"submit\" value=\"VIEW HMCE/IOMCE bet numbering records\">"
        . "</form>";
}

Bar("Monthly Client Reports");
{
    my $yyyymm = DateTime->now->subtract(months => 1)->ymd('-');
    $yyyymm =~ s/-..$//;

    BOM::Platform::Context::template->process('backoffice/account/monthly_client_report.tt', {yyyymm => $yyyymm})
        || die BOM::Platform::Context::template->error();
}

# RESCIND FREE GIFT
Bar("RESCIND FREE GIFTS");

print "If an account is opened, gets a free gift, but never trades for XX days, then rescind the free gift :";
print " <font color=red>DO NOT RUN THIS FOR MLT DUE TO LGA REQUIREMENTS</font>";

print "<form action=\""
    . request()->url_for('backoffice/f_rescind_freegift.cgi')
    . "\" method=post>"
    . "<input type=hidden name=broker value=$broker>"
    . "Days of inactivity: <input type=text size=8 name=inactivedays value=90> "
    . "<br />Message: <input type=text size=50 name=message value='Rescind of free gift for cause of inactivity'> "
    . "<br /><select name=whattodo><option>Simulate<option>Do it for real !</select>"
    . "<input type=submit value='Rescind free gifts'>"
    . "</form>";

Bar("CLEAN UP GIVEN LIST OF ACCOUNTS");

print "Paste here a list of accounts to rescind all their cash balances (separate with commas):";

print "<form action=\""
    . request()->url_for('backoffice/f_rescind_listofaccounts.cgi')
    . "\" method=post>"
    . "<input type=hidden name=broker value=$broker>"
    . "List of accounts: <input type=text size=60 name=listaccounts value='CBET1020,CBET1021'> (separate with commas)"
    . "<br />Message: <input type=text size=65 name=message value='Account closed. Please contact customer support for assistance.'> "
    . "<br /><select name=whattodo><option>Simulate<option>Do it for real !</select>"
    . " <input type=submit value='Rescind these accounts!'>"
    . "</form>";

Bar("USEFUL EXCHANGE RATES");

print "The following exchange rates are from our live data feed. They are live rates as of right now (" . Date::Utility->new->datetime . "<ul>";

foreach my $curr (qw(GBPUSD EURUSD USDHKD USDCNY AUDUSD GBPHKD AUDHKD EURHKD)) {
    my $underlying = BOM::Market::Underlying->new('frx' . $curr);
    print "<li>$curr: " . $underlying->spot . "</li>";
}
print "</ul>";

print "<p>Inter-bank interest rates (from BBDL=Bloomberg Data License):</p>";
print "<table><tr><th>Currency</th><th>1 week</th><th>1 month</th></tr>";

foreach my $currency_symbol (qw(AUD GBP EUR USD HKD)) {
    my $currency = BOM::Market::Currency->new($currency_symbol);
    print '<tr><td>'
        . $currency_symbol
        . '</td><td>'
        . $currency->rate_for(7 / 365) * 100
        . '%</td><td>'
        . $currency->rate_for(30 / 365) * 100
        . '%</td></tr>';
}
print '</table>';

Bar("Japan Open Contracts Report");

print "<form action=\""
    . request()->url_for('backoffice/open_contracts_report.cgi')
    . "\" method=post>"
    . "<input type=hidden name=broker value=$broker>"
    . "DateTime: <input type=text size=30 name=datetime>  Note: In Japanese timezone, format: 2016-03-03 00:00:00"
    . "<br/>Loginid: <input type=text size=30 name=loginid> Note: Input single loginid if running report for single client. For all clients, leave this field empty."
    . "<br/><input type=submit value='Generate report'>"
    . "</form>";

code_exit_BO();
