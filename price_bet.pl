
use strict;
use warnings;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );
use BOM::Database::ClientDB;

my %input = (
    datetime => '2016-03-10',
#    loginid => 'JP1035',
);


my $datetime = $input{datetime};
my $loginid;
$loginid = $input{loginid} if $input{loginid};


my $sql = qq{
SELECT
    c.loginid,
    c.last_name || ' ' || c.first_name as name,

    t.id as buy_transaction_id,
    b.id as bet_id,

    (b.start_time AT TIME ZONE 'UTC' AT TIME ZONE 'JST')::TEXT as trading_start_time,
    (b.expiry_time AT TIME ZONE 'UTC' AT TIME ZONE 'JST')::TEXT  as trading_end_time,

    CASE
        WHEN b.bet_class = 'higher_lower_bet'   THEN 'Ladder'
        WHEN b.bet_class = 'touch_bet'          THEN 'Touch / No Touch'
        WHEN b.bet_class = 'range_bet'          THEN 'Range In / Out'
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
    AND (b.is_sold = false OR b.sell_time >= ?)
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

    $ref->{mtm_price}    = $contract->is_valid_to_sell ? $contract->bid_price : '';
    $ref->{entry_spot}   = $contract->entry_tick ? $contract->entry_tick->quote : '';
    $ref->{current_spot} = $contract->current_spot;
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
);

local $\ = "\n";
open my $fh, '>:utf8', '/tmp/japan_open_contract.csv';
print $fh join(',', @fields);

foreach my $ref (@$open_contracts) {
    print $fh join(',', map { $ref->{$_} } @fields);
}

close $fh;

