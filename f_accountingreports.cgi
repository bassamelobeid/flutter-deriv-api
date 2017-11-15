#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use HTML::Entities;

use List::MoreUtils qw(any);
use Try::Tiny;
use DateTime;
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('ACCOUNTING REPORTS');
my $broker           = request()->broker_code;
my $all_currencies   = request()->available_currencies;
my $currency_options = get_currency_options();
my $feedloc          = BOM::Platform::Runtime->instance->app_config->system->directory->feed;
my $dbloc            = BOM::Platform::Runtime->instance->app_config->system->directory->db;

my $encoded_broker = encode_entities($broker);
my $now            = Date::Utility->new;
my $lastmonth      = $now->months_ahead(-1);

# Daily Turnover Report
Bar("DAILY TURNOVER REPORT");

print "<form action=\"" . request()->url_for('backoffice/f_dailyturnoverreport.cgi') . "\" method=post>";
print "<input type=hidden name=broker value=$encoded_broker>";
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

Bar("Monthly Client Reports");
{
    my $yyyymm = DateTime->now->subtract(months => 1)->ymd('-');
    $yyyymm =~ s/-..$//;

    BOM::Backoffice::Request::template->process('backoffice/account/monthly_client_report.tt', {yyyymm => $yyyymm})
        || die BOM::Backoffice::Request::template->error();
}

# RESCIND FREE GIFT
Bar("RESCIND FREE GIFTS");

print "If an account is opened, gets a free gift, but never trades for XX days, then rescind the free gift :";
print " <font color=red>DO NOT RUN THIS FOR MLT DUE TO LGA REQUIREMENTS</font>";

print "<form action=\""
    . request()->url_for('backoffice/f_rescind_freegift.cgi')
    . "\" method=post>"
    . "<input type=hidden name=broker value=$encoded_broker>"
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
    . "<input type=hidden name=broker value=$encoded_broker>"
    . "List of accounts: <input type=text size=60 name=listaccounts value='CBET1020,CBET1021'> (separate with commas)"
    . "<br />Message: <input type=text size=65 name=message value='Account closed.'> "
    . "<br /><select name=whattodo><option>Simulate<option>Do it for real !</select>"
    . " <input type=submit value='Rescind these accounts!'>"
    . "</form>";

Bar("USEFUL EXCHANGE RATES");

print "The following exchange rates are from our live data feed. They are live rates as of right now (" . Date::Utility->new->datetime . ")" . "<ul>";

foreach my $curr (qw(GBPUSD EURUSD USDHKD USDCNY AUDUSD GBPHKD AUDHKD EURHKD BTCUSD)) {
    try {
        my $underlying = create_underlying('frx' . $curr);
        print "<li>$curr: " . $underlying->spot . "</li>";
    }
    catch {
        warn "Failed to get exchange rate for $curr - $_\n";
        print '<li>' . $curr . ': <span style="color:red;">ERROR</span></li>';
    }
}
print "</ul>";

print "<p>Inter-bank interest rates (from BBDL=Bloomberg Data License):</p>";
print "<table><tr><th>Currency</th><th>1 week</th><th>1 month</th></tr>";

foreach my $currency_symbol (qw(AUD GBP EUR USD HKD)) {
    try {
        my $currency = Quant::Framework::Currency->new({
            symbol           => $currency_symbol,
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        });
        print '<tr><td>'
            . $currency_symbol
            . '</td><td>'
            . $currency->rate_for(7 / 365) * 100
            . '%</td><td>'
            . $currency->rate_for(30 / 365) * 100
            . '%</td></tr>';
    }
    catch {
        warn "Failed to get currency interest rates for $currency_symbol - $_\n";
        print '<tr><td>' . $currency_symbol . '</td><td colspan="2" style="color:red;">ERROR</td></tr>';

    }
}
print '</table>';

Bar("Japan Open Contracts Report");

print "<form action=\""
    . request()->url_for('backoffice/open_contracts_report.cgi')
    . "\" method=post>"
    . "<input type=hidden name=broker value=$encoded_broker>"
    . "DateTime: <input type=text size=30 name=datetime>  Note: In Japanese timezone, format: 2016-03-03 00:00:00"
    . "<br/>Loginid: <input type=text size=30 name=loginid> Note: Input single loginid if running report for single client. For all clients, leave this field empty."
    . "<br/><input type=submit value='Generate report'>"
    . "</form>";

code_exit_BO();
