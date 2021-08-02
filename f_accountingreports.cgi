#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use HTML::Entities;

use List::MoreUtils qw(any);
use Syntax::Keyword::Try;
use f_brokerincludeall;
use ExchangeRates::CurrencyConverter qw(convert_currency);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::MarketData::Types;
use BOM::Config;
use BOM::Backoffice::Sysinit ();
use Log::Any qw($log);
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

print '<form action="'
    . request()->url_for('backoffice/f_dailyturnoverreport.cgi')
    . '" method="post" onsubmit="return validate_month()" class="row">';
print "<input type=hidden name=broker value=$encoded_broker>";
my $today = Date::Utility->today;
my $month = $today->year . '-' . sprintf("%02d", $today->month);

print '<label>Month:</label><input type=text size=12 name=month value="' . $month . '" required pattern="\d{4}-\d{2}" data-lpignore="true" />';
print
    "<input type=\"submit\" class=\"btn btn--primary\" value=\"Daily turnover report\"><strong class=\"error\">CLICK ONLY ONCE!</strong>&nbsp;&nbsp;Be patient if slow to respond.";
print "</form>";

Bar("Monthly Client Reports");
{
    my $yyyymm = Date::Utility->new->date_yyyymmdd;
    $yyyymm =~ s/-..$//;

    BOM::Backoffice::Request::template()->process('backoffice/account/monthly_client_report.tt', {yyyymm => $yyyymm})
        || die BOM::Backoffice::Request::template()->error(), "\n";
}

Bar("USEFUL EXCHANGE RATES");

print "<p>The following exchange rates are from our exchange rates listener. They are live rates as of right now ("
    . Date::Utility->new->datetime . ")<p>" . "<ul>";

my $currency_pairs = BOM::Config::currency_pairs_backoffice()->{currency_pairs};

foreach my $pair (@$currency_pairs) {

    my $pair_name = join '/', @$pair;
    my $underlying_spot = convert_currency(1.00, @$pair);

    try {
        print "<li>" . $pair_name . " : " . $underlying_spot . "</li>";
    } catch ($e) {
        $log->warn("Failed to get exchange rate for $pair_name - $e");
        print '<li>' . $pair_name . ': <span class="error">ERROR</span></li>';
    }

}

print "</ul>";

print qq~
    <p>Inter-bank interest rates (from BBDL=Bloomberg Data License):</p>
    <table class='hover alternate collapsed border'>
        <thead>
            <tr>
                <th>Currency</th>
                <th>1 week</th>
                <th>1 month</th>
            </tr>
        </thead>
        <tbody>
~;

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
    } catch ($e) {
        $log->warn("Failed to get currency interest rates for $currency_symbol - $e");
        print '<tr><td>' . $currency_symbol . '</td><td colspan="2" class="error">ERROR</td></tr>';
    }
}
print '</tbody></table>';

Bar("Aggregate Balance Per Currency");

print '<form action="'
    . request()->url_for('backoffice/aggregate_balance.cgi')
    . '" method=get>'
    . '<label>Run this only on master server:</label>'
    . '<input type="submit" class="btn btn--primary" value="Generate" />'
    . '</form>';

print <<QQ;
<script type="text/javascript" language="javascript">
function validate_month(){
    var get_value = function(elm_name) {
        return (document.getElementsByName(elm_name)[0] || {}).value;
    }
    var month = get_value('month');
    var month_obj = new Date(month);
    if(/^0000/.test(month) || month_obj == 'Invalid Date'){
        alert("Invalid month or year entered.");
        return false;
    }
    return true;
}
</script>
QQ

Bar("Ewallet.exchange Tool");
my $form;

BOM::Backoffice::Request::template()->process(
    'backoffice/e_wallet_tool_form.html.tt',
    {
        broker     => $broker,
        upload_url => request()->url_for('backoffice/f_upload_ewallet.cgi'),
    },
    \$form
) || die BOM::Backoffice::Request::template()->error(), "\n";

print $form;

code_exit_BO();
