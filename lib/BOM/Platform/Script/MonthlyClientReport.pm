package BOM::Platform::Script::MonthlyClientReport;
use strict;
use warnings;

use File::Path qw(make_path);
use Text::CSV;
use BOM::Config::Runtime;
use BOM::Database::ClientDB;
use Date::Utility;

my $PREFIX_OUTPUT_PATH = '/db/f_broker';

sub go {
    my %params = @_;

    my $crdr   = $params{crdr}   || die;
    my $broker = $params{broker} || die;

    my $yyyymm = $params{yyyymm} || die;

    # The start date is the first day of that month
    my $start_date = Date::Utility->new("${yyyymm}-01");

    my $month_end = sprintf("%s-%02d", $yyyymm, $start_date->days_in_month);

    my $until_date = $start_date->plus_time_interval("1mo");

    my $buy_sell = {
        credit => 'sell',
        debit  => 'buy'
        }->{$crdr}
        or die 'invalid crdr parameter to MonthlyClientReport';
    my $gt_lt = {
        credit => '>',
        debit  => '<'
    }->{$crdr};
    my $Buy_Sell = ucfirst $buy_sell;
    my $CrDr     = ucfirst $crdr;

    my $csv_dir  = $PREFIX_OUTPUT_PATH . "/$broker/monthly_client_report";
    my $csv_name = $csv_dir . "/${yyyymm}_${crdr}.csv";

    make_path($csv_dir);

    my $sql = <<HERE;

        select
            '$month_end',
            acc.client_loginid,
            'Contract $Buy_Sell',
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
                            when 'account_transfer'       then
                                case
                                    when p.remark like '%MT5%' then 'MT5 Account Transfer'
                                    else 'Account Transfer'
                                end
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

    my $dbic = BOM::Database::ClientDB->new({
            broker_code => $broker,
            operation   => 'backoffice_replica',
        })->db->dbic;

    return $dbic->run(
        fixup => sub {
            my $sth   = $_->prepare($sql);
            my @binds = (
                $start_date->date_yyyymmdd,    # b0
                $until_date->date_yyyymmdd,    # b1
                $buy_sell,                     # b2
                $broker,                       # b3
                $start_date->date_yyyymmdd,    # b4
                $until_date->date_yyyymmdd,    # b5
                $broker,                       # b6
            );

            $sth->execute(@binds);
            my @headers = qw/Date Loginid Description CrDr_Amount Amount Currency Broker Type/;
            my $csv = Text::CSV->new({eol => "\n"});
            my $fh;
            while (my $row = $sth->fetchrow_arrayref) {
                unless ($fh) {
                    $fh = IO::File->new($csv_name, 'w') || die "writing $csv_name: $!";
                    $csv->print($fh, \@headers);
                }
                $csv->print($fh, $row);
            }
            $fh->close if $fh;
            return $sth->rows;
        });
}

sub run {
    my %params = @_;
    STDOUT->autoflush(1);    # flushes stdout progress report faster

    my $date = $params{date} || do {
        my $now = Date::Utility->new->minus_time_interval('1mo');
        sprintf '%s-%02s', $now->year, $now->month;
    };

    printf "Generating reports for date: %s...\n", $date;
    for my $broker (@{$params{brokers} // [qw/ MLT MX MF CR CH /]}) {
        for my $crdr (@{$params{report} // [qw/ debit credit /]}) {
            printf "%5s / %6s: %s.. ", $broker, $crdr, scalar(localtime);
            my $rows = go
                broker => $broker,
                crdr   => $crdr,
                yyyymm => $date;
            printf "%7d records\n", $rows;

        }
    }

    printf "%s: done\n", scalar(localtime);
    return;
}

1;
