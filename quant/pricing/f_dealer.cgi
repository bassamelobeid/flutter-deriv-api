#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use open qw[ :encoding(UTF-8) ];

use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi);
use f_brokerincludeall;
use Try::Tiny;
use Path::Tiny;
use File::ReadBackwards;
use HTML::Entities;
use BOM::User::Client;

use Date::Utility;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::Config;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Backoffice::QuantsAuditLog;
BOM::Backoffice::Sysinit::init();

PrintContentType();

BrokerPresentation('DEALER/LARGE BETS');
my $broker = request()->broker_code;
my $clerk  = BOM::Backoffice::Auth0::get_staffname();
my $now    = Date::Utility->new;
# Get inputs
my $loginID  = request()->param('loginid');
my $currency = request()->param('curr');
my $price    = request()->param('price');
my $buysell  = request()->param('buysell');
my $qty      = request()->param('qty');
my $bet_ref  = request()->param('ref');
my $subject;
my @body;
my $brand            = request()->brand;
my $to               = $brand->emails('alert_quants');
my $encoded_loginID  = encode_entities($loginID);
my $encoded_currency = encode_entities($currency);
my $encoded_broker   = encode_entities($broker);

# Make transaction on client account
if (request()->param('whattodo') eq 'closeatzero') {

    if ($currency !~ /^\w\w\w$/)    { print "Error with curr " . $encoded_currency;        code_exit_BO(); }
    if ($price !~ /^\d*\.?\d*$/)    { print "Error with price " . encode_entities($price); code_exit_BO(); }
    if ($price eq "")               { print "Error : no price entered";                    code_exit_BO(); }
    if ($loginID !~ /^$broker\d+$/) { print "Error with loginid " . $encoded_loginID;      code_exit_BO(); }
    if ($qty !~ /^\d+$/ or $qty > 50) { print "Error with qty " . encode_entities($qty); code_exit_BO(); }

    my $client;
    try {
        $client = BOM::User::Client::get_instance({loginid => $loginID});
    }
    catch {
        print "Cannot get client instance with loginid " . $encoded_loginID;
        code_exit_BO();
    };

    my $ttype = 'CREDIT';

    if (request()->param('buysell') ne 'SELL') {
        print "You can only sell the contract. You had choosen " . encode_entities(request()->param('buysell'));
        code_exit_BO();
    }
    if ($price != 0) { print "You can only close position at zero price"; code_exit_BO(); }

    # Further error checks
    my $fmb_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        client_loginid => $loginID,
        currency_code  => $currency,
    });

    my $fmbs = $fmb_mapper->get_fmb_by_id([$bet_ref]);
    if ($fmbs and @$fmbs) {
        BOM::Database::Helper::FinancialMarketBet->new({
                account_data => {
                    client_loginid => $loginID,
                    currency_code  => $currency
                },
                transaction_data => [({
                            staff_loginid => $clerk,
                            remark        => request()->param('comment')}
                    ) x @$fmbs
                ],
                bet_data => [
                    map { {
                            sell_price => 0,
                            sell_time  => $now->db_timestamp,
                            quantity   => $qty,
                            id         => $_->financial_market_bet_record->id,
                            is_expired => 0,
                        }
                    } @{$fmbs}
                ],
                db => BOM::Database::ClientDB->new({broker_code => $broker})->db,
            })->batch_sell_bet;
    }

    # Logging
    Path::Tiny::path(BOM::Backoffice::Config::config()->{log}->{deposit})
        ->append_utf8($now->datetime
            . "GMT $ttype($buysell) $qty @ $currency$price $bet_ref $loginID clerk=$clerk fellow="
            . request()->param('DCstaff')
            . " DCcode="
            . request()->param('DCcode') . " ["
            . request()->param('comment')
            . "] $ENV{'REMOTE_ADDR'}");

    BOM::Backoffice::QuantsAuditLog::log(
        $clerk,
        "manuallyclosecontractatzeroprice",
        "content: Manually closed the contract [Ref: $bet_ref] at price $currency 0 for client[$loginID]"
    );

    Bar("Done");
    print "Done!<P>
 <FORM target=$encoded_loginID ACTION=\"" . request()->url_for('backoffice/f_manager_history.cgi') . "\" METHOD=\"POST\">
 <input name=loginID type=hidden value=$encoded_loginID>
 <INPUT type=hidden name=\"broker\" value=\"$encoded_broker\">
 <INPUT type=hidden name=\"currency\" value=\"$encoded_currency\">
 <INPUT type=hidden name=\"l\" value=\"EN\">
 <INPUT type=\"submit\" value='View client statement'>
 </FORM>
 <FORM target=$encoded_loginID ACTION=\"" . request()->url_for('backoffice/f_manager_statement.cgi') . "\" METHOD=\"POST\">
 <input name=loginID type=hidden value=$encoded_loginID>
 <INPUT type=hidden name=\"broker\" value=\"$encoded_broker\">
 <INPUT type=hidden name=\"currency\" value=\"$encoded_currency\">
 <INPUT type=hidden name=\"l\" value=\"EN\">
 <INPUT type=\"submit\" value='View client portfolio'>
 </FORM>";

    $subject = "Manually close contract at zero price. ";
    @body    = ("We manually closed the contract [Ref: $bet_ref] at price $currency 0 for client[$loginID]. \n");

    send_email({
        from    => $brand->emails('system'),
        to      => $to,
        subject => $subject,
        message => \@body,
    });

    code_exit_BO();
}

Bar("CLOSE CONTRACT AT ZERO PRICE");
print qq~
<table width=100% border=0 bgcolor=ffffce><tr><td width=100% bgcolor=ffffce>
<FORM name=maketrans onsubmit="return confirm('Are you sure ? Please double-check all inputs.');" method=POST action="~
    . request()->url_for('backoffice/quant/pricing/f_dealer.cgi') . qq~">
<input type=hidden name=whattodo value=closeatzero>
<input type=hidden name=broker value=$encoded_broker>
<select name=buysell><option selected>SELL</select>
<br>PRICE: <select name=curr><option>~ . get_currency_options() . qq~</select>
<input type=hidden size=12 name=price value=0><a>0</a>
<br>QUANTITY: <input type=text size=12 name=qty value=1>
<br>BET REFERENCE (not TXNID) : <input type=text size=12 name=ref value=''>
<br>CLIENT LOGINID: <input type=text size=12 name=loginid value=$encoded_broker>
<br>COMMENT: <input type=text size=45 maxlength=90 name=comment>
<tr><td><input type=submit value='- Close Contract -'></td></tr>
</form>
</td></tr></table>
~;

code_exit_BO();

