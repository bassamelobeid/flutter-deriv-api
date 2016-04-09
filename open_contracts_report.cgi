#!/usr/bin/perl
package main;
use strict 'vars';

use File::Temp;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );
use BOM::Database::ClientDB;
use BOM::Platform::Plack qw/PrintContentType_XSendfile/;
use BOM::Platform::Sysinit ();

use f_brokerincludeall;
BOM::Platform::Sysinit::init();

my $broker = request()->broker->code;
BOM::Backoffice::Auth0::can_access();

my $datetime = request()->param('datetime');
my $loginid = request()->param('loginid');


my $sql = qq{
SELECT
    c.loginid,
    c.last_name || ' ' || c.first_name as name,

    t.id as buy_transaction_id,
    b.id as bet_id,

    (b.start_time AT TIME ZONE 'UTC' AT TIME ZONE 'JST')::TEXT as trading_start_time,
    (b.expiry_time AT TIME ZONE 'UTC' AT TIME ZONE 'JST')::TEXT  as trading_end_time,

    CASE
        WHEN b.bet_type = 'CALLE'           THEN 'Ladder Higher'
        WHEN b.bet_type = 'PUT'             THEN 'Ladder Lower'

        WHEN b.bet_type = 'ONETOUCH'        THEN 'Touch'
        WHEN b.bet_type = 'NOTOUCH'         THEN 'No Touch'

        WHEN b.bet_type = 'EXPIRYRANGEE'    THEN 'Ends In (Ends Between)'
        WHEN b.bet_type = 'EXPIRYMISS'      THEN 'Ends Out (Ends Outside)'

        WHEN b.bet_type = 'RANGE'           THEN 'Stays In (Stays Between)'
        WHEN b.bet_type = 'UPORDOWN'        THEN 'Stays Out (Goes Outside)'

        ELSE 'others'
    END as bet_type,

    regexp_replace(b.underlying_symbol, 'frx', '') as currency_pair,

    round(b.payout_price / 1000, 2) as lot,
    'buy' as buy_sell,

    CASE
        WHEN b.bet_class = 'higher_lower_bet'   THEN h.absolute_barrier::TEXT
        WHEN b.bet_class = 'touch_bet'          THEN tn.absolute_barrier::TEXT
        WHEN b.bet_class = 'range_bet'          THEN r.absolute_higher_barrier::TEXT || '; ' || r.absolute_lower_barrier::TEXT
    END as exercise_price,

    b.buy_price,
    b.payout_price as payout,
    b.short_code,
    a.currency_code

FROM
    betonmarkets.client c
    JOIN transaction.account a
        ON c.loginid = a.client_loginid AND a.is_default = true
    JOIN transaction.transaction t
        ON a.id = t.account_id
    JOIN bet.financial_market_bet b
        ON t.financial_market_bet_id = b.id
    LEFT JOIN bet.higher_lower_bet h
        ON b.id = h.financial_market_bet_id
    LEFT JOIN bet.touch_bet tn
        ON b.id = tn.financial_market_bet_id
    LEFT JOIN bet.range_bet r
        ON b.id = r.financial_market_bet_id
WHERE
    t.action_type = 'buy'
    AND (t.transaction_time AT TIME ZONE 'UTC' AT TIME ZONE 'JST') < ?
    AND ( b.is_sold = false OR (b.sell_time AT TIME ZONE 'UTC' AT TIME ZONE 'JST' >= ?) )
    ##LOGINID_ONLY##
ORDER BY t.transaction_time
};


my @params = ($datetime, $datetime);

if ($loginid) {
    $sql =~ s/##LOGINID_ONLY##/ AND loginid = ? /g;
    push @params, $loginid;
} else {
    $sql =~ s/##LOGINID_ONLY##//g;
}

my $dbh = BOM::Database::ClientDB->new({
        broker_code => 'JP',
    })->db->dbh;
my $sth = $dbh->prepare($sql);

$sth->execute(@params);
my $open_contracts = $sth->fetchall_arrayref({});

foreach my $ref (@$open_contracts) {
    my $bet_params = shortcode_to_parameters($ref->{short_code}, $ref->{currency_code});
    $bet_params->{date_pricing} = $datetime;
    my $contract = produce_contract($bet_params);

    $ref->{mtm_price}     = $contract->is_valid_to_sell ? $contract->bid_price : '';
    $ref->{entry_spot}    = $contract->entry_tick ? $contract->entry_tick->quote : '';
    $ref->{current_spot}  = $contract->current_spot;
    $ref->{unrealized_pl} = ($ref->{mtm_price}) ? $ref->{mtm_price} - $ref->{buy_price} : '';
}

my @fields = qw(
    loginid
    name
    buy_transaction_id
    bet_id
    trading_start_time
    trading_end_time
    bet_type
    currency_pair
    lot
    buy_sell
    exercise_price
    buy_price
    payout
    mtm_price
    entry_spot
    current_spot
    unrealized_pl
);

local $\ = "\n";
my $filename = File::Temp->new(SUFFIX => '.csv')->filename;

open my $fh, '>:utf8', $filename;
print $fh join(',', @fields);

foreach my $ref (@$open_contracts) {
    print $fh join(',', map { $ref->{$_} } @fields);
}
close $fh;

PrintContentType_XSendfile($filename, 'application/octet-stream');
BOM::Platform::Sysinit::code_exit();

