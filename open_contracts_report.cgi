#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use File::Temp;
use BOM::Product::ContractFactory qw(produce_contract);
use Finance::Contract::Longcode qw( shortcode_to_parameters );
use BOM::Database::ClientDB;
use BOM::Backoffice::PlackHelpers qw/PrintContentType_XSendfile/;
use BOM::Backoffice::Sysinit ();
use Volatility::EconomicEvents;
use BOM::Platform::Chronicle;
use Quant::Framework::EconomicEventCalendar;

use f_brokerincludeall;
BOM::Backoffice::Sysinit::init();

my $broker = request()->broker_code;

# Datettime is in JST
my $datetime = request()->param('datetime');
my $loginid  = request()->param('loginid');

my $sql = qq{
SELECT
    c.loginid,
    c.last_name || ' ' || c.first_name as name,

    t.id as buy_transaction_id,
    b.id as bet_id,

    (b.start_time AT TIME ZONE 'UTC' AT TIME ZONE 'JST')::TEXT as trading_start_time,
    (b.expiry_time AT TIME ZONE 'UTC' AT TIME ZONE 'JST')::TEXT  as trading_end_time,
    (qv.trading_period_start AT TIME ZONE 'UTC' AT TIME ZONE 'JST')::TEXT  as trading_period_start_time,

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

    1 as lot,
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
    LEFT JOIN data_collection.quants_bet_variables qv
        ON t.id = qv.transaction_id
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

my $dbic = BOM::Database::ClientDB->new({
        broker_code => 'JP',
    })->db->dbic;
my $open_contracts = $dbic->run(
    fixup => sub {
        my $sth = $_->prepare($sql);

        $sth->execute(@params);
        return $sth->fetchall_arrayref({});
    });

foreach my $ref (@$open_contracts) {
    my $bet_params = shortcode_to_parameters($ref->{short_code}, $ref->{currency_code});
    my $hour = Date::Utility->today->timezone_offset('Asia/Tokyo')->hours;
    $bet_params->{date_pricing}    = Date::Utility->new($datetime)->minus_time_interval($hour . 'h');
    $bet_params->{landing_company} = 'japan';
    my $contract = produce_contract($bet_params);

    my $seasonality_prefix = 'bo_' . time . '_';

    Volatility::EconomicEvents::set_prefix($seasonality_prefix);
    my $EEC = Quant::Framework::EconomicEventCalendar->new({
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(1),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    });
    my $events = $EEC->get_latest_events_for_period({
            from => $contract->date_start,
            to   => $contract->date_start->plus_time_interval('6d'),
        },
        $contract->underlying->for_date
    );
    Volatility::EconomicEvents::generate_variance({
        underlying_symbols => [$contract->underlying->symbol],
        economic_events    => $events,
        date               => $contract->date_start,
        chronicle_writer   => BOM::Platform::Chronicle::get_chronicle_writer(),
    });

    $ref->{mtm_price}     = $contract->bid_price;
    $ref->{entry_spot}    = $contract->entry_spot;
    $ref->{current_spot}  = $contract->current_spot;
    $ref->{unrealized_pl} = $ref->{mtm_price} - $ref->{buy_price};
}

my @fields = qw(
    loginid
    name
    buy_transaction_id
    bet_id
    trading_start_time
    trading_end_time
    trading_period_start_time
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

open my $fh, '>:encoding(UTF-8)', $filename;
print $fh join(',', @fields);

foreach my $ref (@$open_contracts) {
    print $fh join(',', map { $ref->{$_} // '' } @fields);
}
close $fh;

PrintContentType_XSendfile($filename, 'application/octet-stream');
code_exit_BO();

