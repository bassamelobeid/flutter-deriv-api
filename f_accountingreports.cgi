#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use HTML::Entities;

use List::MoreUtils qw(any);
use Try::Tiny;
use f_brokerincludeall;
use ExchangeRates::CurrencyConverter qw(convert_currency);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::MarketData::Types;
use BOM::Config;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('ACCOUNTING REPORTS');

my $broker           = request()->broker_code;
my $all_currencies   = request()->available_currencies;
my $currency_options = get_currency_options();
my $feedloc          = BOM::Config::Runtime->instance->app_config->system->directory->feed;
my $dbloc            = BOM::Config::Runtime->instance->app_config->system->directory->db;

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

Bar("Monthly Client Reports");
{
    my $yyyymm = Date::Utility->new->plus_time_interval('1mo')->date_yyyymmdd;
    $yyyymm =~ s/-..$//;

    BOM::Backoffice::Request::template()->process('backoffice/account/monthly_client_report.tt', {yyyymm => $yyyymm})
        || die BOM::Backoffice::Request::template()->error();
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

print "The following exchange rates are from our exchange rates listener. They are live rates as of right now ("
    . Date::Utility->new->datetime . ")" . "<ul>";

my $currency_pairs = BOM::Config::currency_pairs_backoffice()->{currency_pairs};

foreach my $pair (@$currency_pairs) {

    my $pair_name = join '/', @$pair;
    my $underlying_spot = convert_currency(1.00, @$pair);

    try {
        print "<li>" . $pair_name . " : " . $underlying_spot . "</li>";
    }
    catch {
        warn "Failed to get exchange rate for $pair_name - $_\n";
        print '<li>' . $pair_name . ': <span style="color:red;">ERROR</span></li>';
    }

}

print "</ul>";

print "<p>Inter-bank interest rates (from BBDL=Bloomberg Data License):</p>";
print "<table><tr><th>Currency</th><th>1 week</th><th>1 month</th></tr>";

foreach my $currency_symbol (qw(AUD GBP EUR USD HKD)) {
    try {
        my $currency = Quant::Framework::Currency->new({
            symbol           => $currency_symbol,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
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

Bar("Aggregate Balance Per Currency");

print '<form action="'
    . request()->url_for('backoffice/aggregate_balance.cgi')
    . '" method=get>'
    . '<br/>Run this only on master server.'
    . ' <input type=submit value="Generate">'
    . '</form>';

code_exit_BO();
