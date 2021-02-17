#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;

use BOM::User::Client;

use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::DataMapper::Transaction;
use BOM::Transaction;
use BOM::Transaction::Utility;
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Backoffice::Request qw(request localize);
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use BOM::Transaction;
use HTML::Entities;
use BOM::Backoffice::Sysinit ();
use JSON::MaybeUTF8 qw(:v1);
BOM::Backoffice::Sysinit::init();

local $\ = "\n";
my $loginID         = uc(request()->param('loginID') // '');
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

if ($loginID !~ /^$broker/) {
    code_exit_BO("Error : wrong loginID $encoded_loginID");
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginID, db_operation => 'backoffice_replica'}) };
if (not $client) {
    code_exit_BO('ERROR : No such client $encoded_loginID.');
}

my $client_email = $client->email;

Bar("$loginID ($client_email) Portfolio");

print "<form style=\"float:left\" action=\"" . request()->url_for('backoffice/f_clientloginid_edit.cgi') . "\" METHOD=get>";
print "<input type=hidden name=broker value=$encoded_broker>";
print "<input type=hidden name=loginID value=\"$encoded_loginID\">";
print "<INPUT type=\"submit\" class=\"btn btn--primary\" value=\"Edit $encoded_loginID details\">";
print "</form> <form style=\"float:right\" action=\"" . request()->url_for('backoffice/f_manager_statement.cgi') . "\" method=\"POST\">
Quick jump to see another portfolio: <input name=loginID type=text size=15 value='$encoded_broker' data-lpignore='true' />";
print "<input type=hidden name=\"outputtype\" value=\"table\">";
print "<input type=hidden name=\"broker\" value=\"$encoded_broker\">";
print "<input type=hidden name=\"l\" value=\"EN\">";
print "<INPUT type=\"submit\" class=\"btn btn--primary\" value=\"Go\"></form>

<form style=\"float:left\" action=\"" . request()->url_for('backoffice/f_manager_history.cgi') . "\" method=\"POST\">
<input type=hidden name=\"loginID\" value=\"$encoded_loginID\" />
<input type=hidden name=\"broker\" value=\"$encoded_broker\" />
<input type=hidden name=\"l\" value=\"EN\" />
<input type=submit class=\"btn btn--primary\" value=\"Client statement\" />
</form><div style=\"clear:both\"></div><br>";

BOM::Transaction::sell_expired_contracts({
    client => $client,
});

my $open_bets = get_open_contracts($client);
foreach my $open_bet (@$open_bets) {
    my $bet_parameters = shortcode_to_parameters($open_bet->{short_code}, $client->currency);
    if ($open_bet->{bet_class} eq 'multiplier') {
        $bet_parameters->{limit_order} = BOM::Transaction::Utility::extract_limit_orders($open_bet);
        $open_bet->{limit_order} =
            encode_json_utf8($bet_parameters->{limit_order});
    }
    my $bet = produce_contract($bet_parameters);
    $open_bet->{description} = localize($bet->longcode);
    if ($bet->may_settle_automatically) {
        $open_bet->{sale_price} = $bet->bid_price;
    }
}

my $acnt_dm = BOM::Database::DataMapper::Account->new({
        client_loginid => $client->loginid,
        currency_code  => $client->currency,
        db             => BOM::Database::ClientDB->new({
                client_loginid => $client->loginid,
                operation      => 'replica'
            }
        )->db,
    });

BOM::Backoffice::Request::template()->process(
    'backoffice/account/portfolio.html.tt',
    {
        open_bets => $open_bets,
        balance   => $acnt_dm->get_balance(),
        currency  => $client->currency,
        loginid   => $client->loginid,
    },
) || die BOM::Backoffice::Request::template()->error();

code_exit_BO();
