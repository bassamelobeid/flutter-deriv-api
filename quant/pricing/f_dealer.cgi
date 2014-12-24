#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/bom/cgi);
use f_brokerincludeall;
use Try::Tiny;
use Path::Tiny;

use BOM::Utility::Date;
use BOM::Utility::Format::Numbers qw(roundnear);
use BOM::Product::Contract::ContractCategory::ContractType::Registry;
use BOM::Platform::Data::Persistence::DataMapper::FinancialMarketBet;
use BOM::Platform::Data::Persistence::ConnectionBuilder;
use BOM::Platform::Helper::Model::FinancialMarketBet;
use BOM::Platform::Transaction;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use BOM::Product::ContractFactory qw( produce_contract );

BOM::Platform::Sysinit::init();

PrintContentType();

BrokerPresentation('DEALER/LARGE BETS');
my $broker  = request()->broker->code;
my $staff   = BOM::Platform::Auth0::can_access(['Quants']);
my $clerk   = BOM::Platform::Auth0::from_cookie()->{nickname};
my $betcode = request()->param('betcode');
$betcode =~ s/\s+//;
my $now = BOM::Utility::Date->new;
# Get inputs
my $loginID  = request()->param('loginid');
my $currency = request()->param('curr');
my $price    = request()->param('price');
my $buysell  = request()->param('buysell');
my $qty      = request()->param('qty');
my $bet_ref  = request()->param('ref');
my $subject;
my @body;
my $to = BOM::Platform::Runtime->instance->app_config->system->alerts->quants . ','
    . BOM::Platform::Context::request()->website->config->get('customer_support.email');

# Make transaction on client account
if (request()->param('whattodo') eq 'maketrans' or request()->param('whattodo') eq 'closeatzero') {

    if ($currency !~ /^\w\w\w$/)    { print "Error with curr " . request()->param('curr');       code_exit_BO(); }
    if ($price !~ /^\d*\.?\d*$/)    { print "Error with price " . request()->param('price');     code_exit_BO(); }
    if ($price eq "")               { print "Error : no price entered";                          code_exit_BO(); }
    if ($loginID !~ /^$broker\d+$/) { print "Error with loginid " . request()->param('loginid'); code_exit_BO(); }
    if ($betcode !~ /^[\w\.\-]+$/)  { print "Error with betcode $betcode";                       code_exit_BO(); }
    if ($qty !~ /^\d+$/ or request()->param('qty') > 50) { print "Error with qty " . request()->param('qty'); code_exit_BO(); }

    my $client;
    try {
        $client = BOM::Platform::Client::get_instance({loginid => request()->param('loginid')});
    }
    catch {
        print "Cannot get client instance with loginid " . request()->param('loginid');
        code_exit_BO();
    };

    my $ttype;
    if   ($buysell eq 'BUY') { $ttype = 'DEBIT'; }
    else                     { $ttype = 'CREDIT'; }

    if (request()->param('whattodo') eq 'maketrans') {
        if ($buysell ne 'BUY' and $buysell ne 'SELL') { print "Error with buysell " . request()->param('buysell'); code_exit_BO(); }
        #check if control code already used
        my $count    = 0;
        my $log_file = File::ReadBackwards->new("/var/log/fixedodds/fmanagerconfodeposit.log");
        while ((defined(my $l = $log_file->readline)) and ($count++ < 200)) {
            my $dc_code = request()->param('DCcode');
            if ($l =~ /DCcode\=$dc_code/i) { print "ERROR: this control code has already been used today!"; code_exit_BO(); }
        }

    } elsif (request()->param('whattodo') eq 'closeatzero') {

        if (request()->param('buysell') ne 'SELL') {
            print "You can only sell the contract. You had choosen " . request()->param('buysell');
            code_exit_BO();
        }
        if (request()->param('price') != 0) { print "You can only close position at zero price"; code_exit_BO(); }
    }

    # Further error checks
    my $fmb_mapper = BOM::Platform::Data::Persistence::DataMapper::FinancialMarketBet->new({
        client_loginid => $loginID,
        currency_code  => $currency,
    });

    if ($buysell eq 'BUY') {
        my $bal = BOM::Platform::Data::Persistence::DataMapper::Account->new({
                'client_loginid' => $loginID,
                'currency_code'  => $currency
            })->get_balance();
        if ($bal < $price) { print "Error : insufficient client account balance. Client balance is only $currency$bal"; code_exit_BO(); }
    } elsif ($buysell eq 'SELL') {
        my $stockonhand = $fmb_mapper->get_number_of_open_bets_with_shortcode_of_account($betcode);

        if ($qty > $stockonhand + 0.000001) {
            if   ($stockonhand == 0) { print "Error: Client $loginID does not own $betcode in $currency"; }
            else                     { print "Error: you cannot sell $qty as $loginID only owns $stockonhand of $betcode" }
            code_exit_BO();
        }

        if ($qty != $stockonhand) {
            print "Error: you cannot sell $qty as $loginID owns $stockonhand of $betcode. <br> All of the positions have to be sold at once";
            code_exit_BO();
        }
    } else {
        print "Error: unknown instruction buysell=$buysell";
        code_exit_BO();
    }

    if (request()->param('whattodo') eq 'closeatzero') {
        if (not BOM::Platform::Transaction->freeze_client($loginID)) {
            die "Account stuck in previous transaction $loginID";
        }

        my $db = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
                operation   => 'write',
                broker_code => $broker,
            })->db;

        my $fmbs       = $fmb_mapper->get_fmb_by_shortcode($betcode);
        my $fmb_helper = BOM::Platform::Helper::Model::FinancialMarketBet->new({
            bet => $fmbs->[0],
            db  => $db
        });

        $fmb_helper->sell_bet({
            sell_price    => 0,
            sell_time     => $now->db_timestamp,
            staff_loginid => $clerk,
        });
    } else {
        # check short code
        my $bet = produce_contract($betcode, $currency);

        if ($bet->longcode =~ /UNKNOWN|Unknown/) { print "Error : BOM::Product::Contract returned unknown bet code!"; code_exit_BO(); }

        if ($bet->payout > 50001) { print "Error : Payout is higher than 50000. Payout=" . $bet->payout; code_exit_BO(); }
        if ($bet->payout < $price) {
            print "Error : Bet price is higher than payout: payout=" . $bet->payout . ' price=' . $price;
            code_exit_BO();
        }
        # add other checks below..

        if (not BOM::Platform::Transaction->freeze_client($loginID)) {
            die "Account stuck in previous transaction $loginID";
        }
        #pricing comment
        my $pricingcomment = request()->param('comment');
        my $transaction    = BOM::Product::Transaction->new({
            client   => $client,
            contract => $bet,
            action   => $buysell,
            price    => $price,
            comment  => $pricingcomment,
            staff    => $clerk,
        });
        my $error = $transaction->update_client_db;
        die $error->{-message_to_client} if $error;
    }

    BOM::Platform::Transaction->unfreeze_client($loginID);

    # Logging
    Path::Tiny::path("/var/log/fixedodds/fmanagerconfodeposit.log")
        ->append($now->datetime
            . "GMT $ttype($buysell) $qty @ $currency$price $betcode $loginID clerk=$clerk fellow="
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

    if (request()->param('whattodo') eq 'maketrans') {

        $subject = "Manually close contract. ";
        @body    = (
            "CS team,\nwe manually closed the contract [Ref: $bet_ref] at price [$currency $price] for clien[$loginID] shortcode[$betcode]. Please inform the client. "
        );
    } elsif (request()->param('whattodo') eq 'closeatzero') {
        $subject = "Manually close contract at zero price. ";
        @body    = ("We manually closed the contract [Ref: $bet_ref] at price $currency 0 for client[$loginID] shortcode[$betcode]. \n");

        push @body, "CS team,\nplease inform the client.";

    }

    send_email({
        from    => BOM::Platform::Runtime->instance->app_config->system->email,
        to      => $to,
        subject => $subject,
        message => \@body,
    });

    code_exit_BO();
}

Bar("MAKE TRANSACTION IN CLIENT ACCOUNT");
print qq~
<table width=100% border=0 bgcolor=ffffce><tr><td width=100% bgcolor=ffffce>
<FORM name=maketrans onsubmit="return confirm('Are you sure ? Please double-check all inputs.');" method=POST action="~
    . request()->url_for('backoffice/quant/pricing/f_dealer.cgi') . qq~">
<input type=hidden name=whattodo value=maketrans>
<input type=hidden name=broker value=$broker>
<select name=buysell><option selected>SELL<option>BUY</select>
<br>BET CODE: <input type=text size=70 name=betcode value=''> <a onclick='document.maketrans.betcode.value=document.dealer.betcode.value'><i>click to grab from above</i></a>
<br>PRICE: <select name=curr><option>~ . get_currency_options() . qq~</select>
<input type=text size=12 name=price value=''> <a onclick='document.maketrans.price.value=document.dealer.price.value'><i>click to grab from above</i></a>
<br>QUANTITY: <input type=text size=12 name=qty value=1>
<br>BET REFERENCE: <input type=text size=12 name=ref value=''>
<br>CLIENT LOGINID: <input type=text size=12 name=loginid value=$broker>
<br>COMMENT: <input type=text size=45 maxlength=90 name=comment>
<br>

<table border=0 cellpadding=1 cellspacing=1><tr><td bgcolor=FFFFEE><font color=blue>
<b>DUAL CONTROL CODE FOR QTY*PRICE</b>
<br>Fellow staff name: <input type=text name=DCstaff size=8>
Control Code: <input type=text name=DCcode size=16>
</td></tr></table>

<br>
<input type=submit value='- Make Transaction -'>
</form>
</td></tr></table>
~;

Bar("CLOSE CONTRACT AT ZERO PRICE");
print qq~
<table width=100% border=0 bgcolor=ffffce><tr><td width=100% bgcolor=ffffce>
<FORM name=maketrans onsubmit="return confirm('Are you sure ? Please double-check all inputs.');" method=POST action="~
    . request()->url_for('backoffice/quant/pricing/f_dealer.cgi') . qq~">
<input type=hidden name=whattodo value=closeatzero>
<input type=hidden name=broker value=$broker>
<select name=buysell><option selected>SELL</select>
<br>BET CODE: <input type=text size=70 name=betcode value=''> <a onclick='document.maketrans.betcode.value=document.dealer.betcode.value'></a>
<br>PRICE: <select name=curr><option>~ . get_currency_options() . qq~</select>
<input type=hidden size=12 name=price value=0><a>0</a>
<br>QUANTITY: <input type=text size=12 name=qty value=1>
<br>BET REFERENCE: <input type=text size=12 name=ref value=''>
<br>CLIENT LOGINID: <input type=text size=12 name=loginid value=$broker>
<br>COMMENT: <input type=text size=45 maxlength=90 name=comment>
<tr><td><input type=submit value='- Close Contract -'></td></tr>
</form>
</td></tr></table>
~;

code_exit_BO();

