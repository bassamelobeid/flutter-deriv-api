#!/usr/bin/perl
package main;

use strict;
use warnings;

use Text::CSV;
use DateTime;
use BOM::Platform::Runtime;
use BOM::Database::ClientDB;

$| = 1; # flushes stdout progress report faster

sub go {
    my %params = @_;

    my $crdr       = $params{crdr}     || die;
    my $broker     = $params{broker}   || die;

    my $yyyymm     = $params{yyyymm}   || do {
        my $now = DateTime->now->subtract(months=>1);
        sprintf '%s-%02s', $now->year, $now->month;
    };

    my ($yyyy,$mm) = $yyyymm =~ /^(\d{4})-(\d{2})$/;
    my $start_date = DateTime->new(year=>$yyyy, month=>$mm);
    my $month_end  = DateTime->last_day_of_month(year=>$yyyy, month=>$mm)->ymd;
    my $until_date = $start_date->clone->add(months=>1);

    my $dep_wth    = {credit=>'deposit', debit=>'withdrawal'}->{$crdr} || die;
    my $buy_sell   = {credit=>'sell'   , debit=>'buy'       }->{$crdr};
    my $gt_lt      = {credit=>'>'      , debit=>'<'         }->{$crdr};
    my $Buy_Sell   = ucfirst $buy_sell;
    my $CrDr       = ucfirst $crdr;

    my $csv_name   = "/db/f_broker/$broker/monthly_client_report/${yyyymm}_${crdr}.csv";

    my $sql = <<HERE;

        select
            '$month_end',
            acc.client_loginid,
            'Bet $Buy_Sell',
            abs(sum(trx.amount)),
            sum(trx.amount),
            acc.currency_code,
            cli.broker_code,
            '$CrDr'
        from transaction.account acc
        join betonmarkets.client cli on acc.client_loginid = cli.loginid
        join transaction.transaction trx on trx.account_id = acc.id
        where
            trx.transaction_time >= ?           -- b0
        and trx.transaction_time <  ?           -- b1
        and trx.action_type = ?                 -- b2
        and trx.amount != 0
        and cli.broker_code = ?                 -- b3
        group by 1,2,3,6,7,8

    union

        select
            '$month_end',
            acc.client_loginid,
            coalesce(   dw.payment_processor,
                        case p.payment_gateway_code
                            when 'affiliate_reward'       then 'Affiliate Reward'
                            when 'account_transfer'       then 'Account Transfer'
                            when 'bank_wire'              then 'Bank Wire'
                            when 'free_gift'              then 'Free Gift'
                            when 'payment_agent_transfer' then 'Payment Agent'
                            when 'payment_fee'            then 'Dormant Fee'
                            when 'western_union'          then 'Western Union'
                            when 'legacy_payment'         then p.payment_type_code
                            else p.payment_gateway_code
                        end
                    ),
            abs(sum(p.amount)),
            sum(p.amount),
            acc.currency_code,
            cli.broker_code,
            '$CrDr'
        from transaction.account acc
        join betonmarkets.client cli on acc.client_loginid = cli.loginid
        join payment.payment p on p.account_id = acc.id
        left join payment.doughflow dw on dw.payment_id = p.id
        where
            p.payment_time >= ?                 -- b4
        and p.payment_time <  ?                 -- b5
        and p.amount $gt_lt 0
        and cli.broker_code = ?                 -- b6
        group by 1,2,3,6,7,8

    order by 6,2,3

HERE

    my $dbh = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'backoffice_replica',
    })->db->dbh;

    my $sth = $dbh->prepare($sql);
    my @binds = (
        $start_date->ymd,   # b0
        $until_date->ymd,   # b1
        $buy_sell,          # b2
        $broker,            # b3
        $start_date->ymd,   # b4
        $until_date->ymd,   # b5
        $broker,            # b6
    );

    $sth->execute(@binds);

    my @headers    = qw/Date Loginid Description CrDr_Amount Amount Currency Broker Type/;
    my $csv = Text::CSV->new({eol=>"\n"});
    my $fh;
    while (my $row = $sth->fetchrow_arrayref) {
        unless ($fh) {
            $fh = IO::File->new($csv_name, 'w') || die "writing $csv_name: $!";
            $csv->print($fh, \@headers);
        }
        $csv->print($fh, $row );
    }
    $fh->close if $fh;
    return $sth->rows;
}

for my $broker (qw/ MLT MX MF CR /) {
    for my $crdr ('debit', 'credit') {
        printf "%5s / %6s: %s.. ", $broker, $crdr, scalar(localtime);
        my $rows = go broker => $broker, crdr => $crdr;
        printf "%7d records\n", $rows;
    }
}
printf "%s: done\n", scalar(localtime);
