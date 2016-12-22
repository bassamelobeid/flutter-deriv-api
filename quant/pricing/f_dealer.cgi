#!/etc/rmg/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi);
use f_brokerincludeall;
use Try::Tiny;
use Path::Tiny;
use File::ReadBackwards;

use Client::Account;

use Date::Utility;
use Format::Util::Numbers qw(roundnear);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Product::ContractFactory qw( produce_contract );

BOM::Backoffice::Sysinit::init();

PrintContentType();

BrokerPresentation('DEALER/LARGE BETS');
my $broker = request()->broker_code;
my $staff  = BOM::Backoffice::Auth0::can_access(['Quants']);
my $clerk  = BOM::Backoffice::Auth0::from_cookie()->{nickname};
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
my $brand = Brands->new(name => request()->brand);
my $to = $brand->emails('alert_quants');

# Make transaction on client account
if (request()->param('whattodo') eq 'closeatzero') {

    if ($currency !~ /^\w\w\w$/)    { print "Error with curr " . request()->param('curr');       code_exit_BO(); }
    if ($price !~ /^\d*\.?\d*$/)    { print "Error with price " . request()->param('price');     code_exit_BO(); }
    if ($price eq "")               { print "Error : no price entered";                          code_exit_BO(); }
    if ($loginID !~ /^$broker\d+$/) { print "Error with loginid " . request()->param('loginid'); code_exit_BO(); }
    if ($qty !~ /^\d+$/ or request()->param('qty') > 50) { print "Error with qty " . request()->param('qty'); code_exit_BO(); }

    my $client;
    try {
        $client = Client::Account::get_instance({loginid => request()->param('loginid')});
    }
    catch {
        print "Cannot get client instance with loginid " . request()->param('loginid');
        code_exit_BO();
    };

    my $ttype = 'CREDIT';

    if (request()->param('buysell') ne 'SELL') {
        print "You can only sell the contract. You had choosen " . request()->param('buysell');
        code_exit_BO();
    }
    if (request()->param('price') != 0) { print "You can only close position at zero price"; code_exit_BO(); }

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
                bet_data => [map { {sell_price => 0, sell_time => $now->db_timestamp, id => $_->financial_market_bet_record->id,} } @{$fmbs}],
                db => BOM::Database::ClientDB->new({broker_code => $broker})->db,
            })->batch_sell_bet;
    }

    # Logging
    Path::Tiny::path("/var/log/fixedodds/fmanagerconfodeposit.log")
        ->append_utf8($now->datetime
            . "GMT $ttype($buysell) $qty @ $currency$price $bet_ref $loginID clerk=$clerk fellow="
            . request()->param('DCstaff')
            . " DCcode="
            . request()->param('DCcode') . " ["
            . request()->param('comment')
            . "] $ENV{'REMOTE_ADDR'}");

    Bar("Done");
    print "Done!<P>
 <FORM target=$loginID ACTION=\"" . request()->url_for('backoffice/f_manager_history.cgi') . "\" METHOD=\"POST\">
 <input name=loginID type=hidden value=$loginID>
 <INPUT type=hidden name=\"broker\" value=\"$broker\">
 <INPUT type=hidden name=\"currency\" value=\"$currency\">
 <INPUT type=hidden name=\"l\" value=\"EN\">
 <INPUT type=\"submit\" value='View client statement'>
 </FORM>
 <FORM target=$loginID ACTION=\"" . request()->url_for('backoffice/f_manager_statement.cgi') . "\" METHOD=\"POST\">
 <input name=loginID type=hidden value=$loginID>
 <INPUT type=hidden name=\"broker\" value=\"$broker\">
 <INPUT type=hidden name=\"currency\" value=\"$currency\">
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
<input type=hidden name=broker value=$broker>
<select name=buysell><option selected>SELL</select>
<br>PRICE: <select name=curr><option>~ . get_currency_options() . qq~</select>
<input type=hidden size=12 name=price value=0><a>0</a>
<br>QUANTITY: <input type=text size=12 name=qty value=1>
<br>BET REFERENCE (not TXNID) : <input type=text size=12 name=ref value=''>
<br>CLIENT LOGINID: <input type=text size=12 name=loginid value=$broker>
<br>COMMENT: <input type=text size=45 maxlength=90 name=comment>
<tr><td><input type=submit value='- Close Contract -'></td></tr>
</form>
</td></tr></table>
~;

code_exit_BO();

