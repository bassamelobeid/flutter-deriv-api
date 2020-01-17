#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Syntax::Keyword::Try;
use Date::Utility;
use Text::CSV;
use Syntax::Keyword::Try;
use BOM::Config::Runtime;
use BOM::Backoffice::PlackHelpers qw( PrintContentType_excel );
use BOM::Database::ClientDB;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my %params = %{request()->params};

my $yyyymm        = $params{yyyymm}            // '';
my $broker        = $params{broker}            // '';
my $payment_types = $params{payment_type}      // '';
my $all_types     = $params{all_payment_types} // '';
my $months        = $params{months}            // 1;

# We construct the download filename from these two values, so let's make sure they're
# sensible before proceeding.
code_exit_BO("Invalid broker code") unless $broker =~ /^[A-Z]{1,6}$/;

my $start_date;
try {
    $yyyymm =~ /^(\d{4})-(\d{2})$/;
    $start_date = Date::Utility->new("$1-$2-01");
}
catch {
    code_exit_BO("Date $yyyymm was not parsed as YYYY-MM, check it");
}

my $until_date = $start_date->plus_time_interval("${months}mo");

my ($payment_filter, $csv_name);

my @binds = (
    $start_date->date_yyyymmdd,    # b0
    $until_date->date_yyyymmdd,    # b1
    $broker,                       # b2
);

if ($all_types) {
    $csv_name = "${broker}_all_payments_$yyyymm.csv";
} else {
    $csv_name = "${broker}_payments_$yyyymm.csv";
    my @payment_types = ref $payment_types ? @$payment_types : ($payment_types);
    $payment_filter = 'and p.payment_type_code in (' . join(',', ('?') x @payment_types) . ')';
    push @binds, @payment_types;
}

PrintContentType_excel($csv_name);

my $sql = <<'START' . ($payment_filter ? <<"FILTER" : '') . <<'END';

    SELECT
        cli.broker_code,
        acc.client_loginid,
        cli.residence,
        p.payment_time,
        CASE WHEN mt5_amount IS NOT NULL 
            THEN
                'mt5_transfer'
            ELSE
                p.payment_gateway_code
        END  as payment_gateway_code,
        p.payment_type_code,
        acc.currency_code,
        p.amount,
        (COALESCE (pt.amount, pgtp.amount, mt5_amount))* -1 AS transferred_amount,
        COALESCE ((SELECT ta.currency_code FROM transaction.account ta WHERE  pgtp.account_id = ta.id OR pt.account_id = ta.id),
         mt5_currency_code) AS currency_code_to,
         p.transfer_fees ,
        TRIM(p.remark)
    from transaction.account acc
    join betonmarkets.client cli on acc.client_loginid = cli.loginid
    join payment.payment p on p.account_id = acc.id
    -- internal transfer
    LEFT JOIN payment.account_transfer pat ON p.id = pat.payment_id
    LEFT JOIN payment.payment pt ON pat.corresponding_payment_id = pt.id
    --payment agent
    LEFT JOIN payment.payment_agent_transfer pgt ON p.id = pgt.payment_id
    LEFT JOIN payment.payment pgtp ON pgt.corresponding_payment_id = pgtp.id
    --mt5
    LEFT JOIN payment.mt5_transfer mt ON p.id = mt.payment_id
    where
        p.payment_time >= ?   -- b0
    and p.payment_time <  ?   -- b1
    and cli.broker_code = ?   -- b2
START
    $payment_filter
FILTER
    order by 1,2,3
END

my $dbic = BOM::Database::ClientDB->new({
        broker_code => $broker,
    })->db->dbic;

$dbic->run(
    fixup => sub {
        my $sth = $_->prepare($sql);
        $sth->execute(@binds);

        my @headers =
            qw/Broker Loginid Residence Timestamp PaymentGateway PaymentType Currency Amount TransferredAmount TransferedCurrency TransferFee Remark/;

        my $csv = Text::CSV->new({eol => "\n"});
        $csv->print(\*STDOUT, \@headers);
        while (my $row = $sth->fetchrow_arrayref) {
            $csv->print(\*STDOUT, $row);
        }

    });

1;

