#!/etc/rmg/bin/perl
package main;
use strict 'vars';

use f_brokerincludeall;

use Client::Account;

use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::DataMapper::Transaction;
use BOM::Transaction;
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Backoffice::Request qw(request);
use HTML::Entities;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

local $\ = "\n";
my $loginID         = uc(request()->param('loginID'));
my $encoded_loginID = encode_entities($loginID);
my $outputtype      = request()->param('outputtype');
if (not $outputtype) {
    $outputtype = 'table';
}

if ($outputtype eq 'csv') {
    print "Content-type: application/csv\n\n";
} else {
    PrintContentType();
    BrokerPresentation("$encoded_loginID Portfolio");
}

my $broker         = request()->broker_code;
my $encoded_broker = encode_entities($broker);
BOM::Backoffice::Auth0::can_access(['CS']);

if ($loginID !~ /^$broker/) {
    print "Error : wrong loginID $encoded_loginID";
    code_exit_BO();
}

my $client = Client::Account::get_instance({'loginid' => $loginID});
if (not $client) {
    print "<B><font color=red>ERROR : No such client $encoded_loginID.<P>";
    code_exit_BO();
}

my $client_email = $client->email;

Bar("$encoded_loginID ($client_email) Portfolio");

print "<form style=\"float:left\" action=\"" . request()->url_for('backoffice/f_clientloginid_edit.cgi') . "\" METHOD=POST>";
print "<input type=hidden name=broker value=$encoded_broker>";
print "<input type=hidden name=loginID value=\"$encoded_loginID\">";
print "<INPUT type=\"submit\" value=\"EDIT $encoded_loginID DETAILS\">";
print "</form><form style=\"float:right\" action=\"" . request()->url_for('backoffice/f_manager_statement.cgi') . "\" method=\"POST\">
Quick jump to see another portfolio: <input name=loginID type=text size=10 value='$encoded_broker'>";
print "<input type=hidden name=\"outputtype\" value=\"table\">";
print "<input type=hidden name=\"broker\" value=\"$encoded_broker\">";
print "<input type=hidden name=\"l\" value=\"EN\">";
print "<INPUT type=\"submit\" value=\"Go\"></form>

<form style=\"float:left\" action=\"" . request()->url_for('backoffice/f_manager_history.cgi') . "\" method=\"POST\">
<input type=hidden name=\"loginID\" value=\"$encoded_loginID\" />
<input type=hidden name=\"broker\" value=\"$encoded_broker\" />
<input type=hidden name=\"l\" value=\"EN\" />
<input type=submit value=\"CLIENT STATEMENT\" />
</form><div style=\"clear:both\"></div>";

BOM::Transaction::sell_expired_contracts({
    client => $client,
});

my $clientdb = BOM::Database::ClientDB->new({
    client_loginid => $client->loginid,
    operation      => 'replica',
});

my $open_bets = $clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$client->loginid, $client->currency, 'false']);
foreach my $open_bet (@{$open_bets}) {
    my $bet = produce_contract($open_bet->{short_code}, $client->currency);
    $open_bet->{description} = $bet->longcode;
    if ($bet->may_settle_automatically) {
        $open_bet->{sale_price} = $bet->bid_price;
    }
}

my $acnt_dm = BOM::Database::DataMapper::Account->new({
    client_loginid => $client->loginid,
    currency_code  => $client->currency,
    db             => $clientdb->db,
});

BOM::Backoffice::Request::template->process(
    'backoffice/account/portfolio.html.tt',
    {
        open_bets => $open_bets,
        balance   => $acnt_dm->get_balance(),
        currency  => $client->currency,
        loginid   => $client->loginid,
    },
) || die BOM::Backoffice::Request::template->error();

code_exit_BO();
