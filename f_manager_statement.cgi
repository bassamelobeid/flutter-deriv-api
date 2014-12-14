#!/usr/bin/perl
package main;
use strict 'vars';

use f_brokerincludeall;
use BOM::Platform::Data::Persistence::DataMapper::FinancialMarketBet;
use BOM::Platform::Data::Persistence::DataMapper::Transaction;
use BOM::Product::Transaction;
use BOM::View::Language;
use BOM::Platform::Plack qw( PrintContentType );

system_initialize();

local $\ = "\n";
my $loginID    = uc(request()->param('loginID'));
my $outputtype = request()->param('outputtype');
if (not $outputtype) {
    $outputtype = 'table';
}

if ($outputtype eq 'csv') {
    print "Content-type: application/csv\n\n";
} else {
    PrintContentType();
    BrokerPresentation("$loginID Portfolio");
}

my $broker = request()->broker->code;
BOM::Platform::Auth0::can_access(['CS']);

if ($loginID !~ /^$broker/) {
    print "Error : wrong loginID $loginID";
    code_exit_BO();
}

my $client = BOM::Platform::Client::get_instance({'loginid' => $loginID});
if (not $client) {
    print "<B><font color=red>ERROR : No such client $loginID.<P>";
    code_exit_BO();
}

my $client_email = $client->email;

Bar("$loginID ($client_email) Portfolio");

print "<form style=\"float:left\" action=\"" . request()->url_for('backoffice/f_clientloginid_edit.cgi') . "\" METHOD=POST>";
print "<input type=hidden name=broker value=$broker>";
print "<input type=hidden name=loginID value=$loginID>";
print "Language: <select name=l>", BOM::View::Language::getLanguageOptions(), "</select>";
print "<INPUT type=\"submit\" value=\"EDIT $loginID DETAILS\">";
print "</form><form style=\"float:right\" action=\"" . request()->url_for('backoffice/f_manager_statement.cgi') . "\" method=\"POST\">
Quick jump to see another portfolio: <input name=loginID type=text size=10 value='$broker'>";
print "<input type=hidden name=\"outputtype\" value=\"table\">";
print "<input type=hidden name=\"broker\" value=\"$broker\">";
print "<input type=hidden name=\"l\" value=\"EN\">";
print "<INPUT type=\"submit\" value=\"Go\"></form>

<form style=\"float:left\" action=\"" . request()->url_for('backoffice/f_manager_history.cgi') . "\" method=\"POST\">
<input type=hidden name=\"loginID\" value=\"$loginID\" />
<input type=hidden name=\"broker\" value=\"$broker\" />
<input type=hidden name=\"l\" value=\"EN\" />
<input type=submit value=\"CLIENT STATEMENT\" />
</form><div style=\"clear:both\"></div>";

if (BOM::Platform::Runtime->instance->app_config->quants->features->enable_portfolio_autosell) {
    BOM::Product::Transaction::sell_expired_contracts({
        client => $client,
    });
}

my $db = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
        client_loginid => $client->loginid,
        operation      => 'read_binary_replica',
    })->db;

my $currency = $client->currency;
my $bet_dm   = BOM::Platform::Data::Persistence::DataMapper::FinancialMarketBet->new({
    client_loginid => $client->loginid,
    currency_code  => $currency,
    db             => $db,
});

my $open_bets = $bet_dm->get_open_bets_of_account();
foreach my $open_bet (@{$open_bets}) {
    my $bet = produce_contract($open_bet->{short_code}, $currency);
    $open_bet->{description} = $bet->longcode;
    if ($bet->may_settle_automatically) {
        $open_bet->{sale_price} = $bet->bid_price;
    }
}

my $acnt_dm = BOM::Platform::Data::Persistence::DataMapper::Account->new({
    client_loginid => $client->loginid,
    currency_code  => $currency,
    db             => $db,
});

BOM::Platform::Context::template->process(
    'backoffice/account/portfolio.html.tt',
    {
        open_bets => $open_bets,
        balance   => $acnt_dm->get_balance(),
        currency  => $currency,
    },
) || die BOM::Platform::Context::template->error();

Bar("Turnover analysis (Getting data from Transaction Database) ");
my $txn_data_mapper = BOM::Platform::Data::Persistence::DataMapper::Transaction->new({
    'client_loginid' => $loginID,
    'currency_code'  => $currency,
    db               => $db,
});
my $turnover = {};
$turnover->{total} = $txn_data_mapper->get_turnover_of_account();

my $bet_data_mapper = BOM::Platform::Data::Persistence::DataMapper::FinancialMarketBet->new({
    'client_loginid' => $loginID,
    'currency_code'  => $currency,
    db               => $db,
});
$turnover->{intraday} = $bet_data_mapper->get_turnover_of_client({
    'bet_type'         => ['INTRA',],
    'overall_turnover' => 1
});

BOM::Platform::Context::template->process(
    'backoffice/account/turnover_analysis.html.tt',
    {
        turnover => $turnover,
        currency => $currency,
    },
) || die BOM::Platform::Context::template->error();

code_exit_BO();
