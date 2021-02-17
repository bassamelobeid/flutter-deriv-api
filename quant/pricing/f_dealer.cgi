#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use open qw[ :encoding(UTF-8) ];

use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi);
use f_brokerincludeall;
use Syntax::Keyword::Try;
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
use BOM::Transaction::Utility;
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

    if ($currency !~ /^[a-zA-Z0-9]{2,20}$/) { code_exit_BO("Error with curr " . $encoded_currency); }
    if ($price !~ /^\d*\.?\d*$/)            { code_exit_BO("Error with price " . encode_entities($price)); }
    if ($price eq "")                       { code_exit_BO('Error : no price entered'); }
    if ($loginID !~ /^$broker\d+$/)         { code_exit_BO("Error with loginid " . $encoded_loginID); }
    if ($qty !~ /^\d+$/ or $qty > 50)       { code_exit_BO("Error with qty " . encode_entities($qty)); }

    my $client;
    try {
        $client = BOM::User::Client::get_instance({loginid => $loginID});
    } catch {
        code_exit_BO("Cannot get client instance with loginid $encoded_loginID");
    }

    my $ttype = 'CREDIT';

    if (request()->param('buysell') ne 'SELL') {
        code_exit_BO('You can only sell the contract. You had choosen ' . encode_entities(request()->param('buysell')));
    }
    if ($price != 0) { code_exit_BO('You can only close position at zero price.'); }

    # Further error checks
    my $fmb_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        client_loginid => $loginID,
        currency_code  => $currency,
    });

    my $fmbs = $fmb_mapper->get_fmb_by_id([$bet_ref]);
    if ($fmbs and @$fmbs) {
        my $sold = BOM::Database::Helper::FinancialMarketBet->new({
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

        for (@$sold) {
            my $item                = $_;
            my $contract_parameters = BOM::Transaction::Utility::build_contract_parameters(
                $client,
                {
                    $item->{fmb}->%*,
                    buy_transaction_id  => $item->{buy_txn_id},
                    sell_transaction_id => $item->{txn}{id}});
            BOM::Transaction::Utility::set_contract_parameters($contract_parameters, time);
        }
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
 <INPUT type=\"submit\" class=\"btn btn--primary\" value='View client statement'>
 </FORM>
 <FORM target=$encoded_loginID ACTION=\"" . request()->url_for('backoffice/f_manager_statement.cgi') . "\" METHOD=\"POST\">
 <input name=loginID type=hidden value=$encoded_loginID>
 <INPUT type=hidden name=\"broker\" value=\"$encoded_broker\">
 <INPUT type=hidden name=\"currency\" value=\"$encoded_currency\">
 <INPUT type=hidden name=\"l\" value=\"EN\">
 <INPUT type=\"submit\" class=\"btn btn--primary\" value='View client portfolio'>
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
<FORM name=maketrans onsubmit="return confirm('Are you sure ? Please double-check all inputs.');" method=POST action="~
    . request()->url_for('backoffice/quant/pricing/f_dealer.cgi') . qq~">
<input type=hidden name=whattodo value=closeatzero>
<input type=hidden name=broker value=$encoded_broker>
<div class='row'><select name=buysell><option selected>SELL</select></div>
<div class='row'><label>Price:</label><select name=curr><option>~ . get_currency_options() . qq~</select>
<input type=hidden size=12 name=price value=0><a>0</a></div>
<div class='row'><label>Quantity:</label><input type=text size=12 name=qty value=1 data-lpignore='true' /></div>
<div class='row'><label>Bet reference (not TXNID):</label><input type=text size=12 name=ref value='' data-lpignore='true' /></div>
<div class='row'><label>Client Login ID:</label><input type=text size=12 name=loginid value=$encoded_broker data-lpignore='true' /></div>
<div class='row'><label>Comment:</label><input type=text size=45 maxlength=90 name=comment data-lpignore='true' /></div>
<div class='row'><input type=submit value='Close contract' class="btn btn--red"></div>
</form>
~;

code_exit_BO();
