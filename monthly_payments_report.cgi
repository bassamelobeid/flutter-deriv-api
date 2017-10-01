#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Text::CSV;
use DateTime;

use BOM::Platform::Runtime;
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
    $start_date = DateTime->new(
        year  => $1,
        month => $2
    );
}
catch {
    code_exit_BO("Date $yyyymm was not parsed as YYYY-MM, check it");
};
my $until_date = $start_date->clone->add(months => $months);

my ($payment_filter, $csv_name);

my @binds = (
    $start_date->ymd,    # b0
    $until_date->ymd,    # b1
    $broker,             # b2
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

    select
        cli.broker_code,
        acc.client_loginid,
        cli.residence,
        p.payment_time,
        p.payment_gateway_code,
        p.payment_type_code,
        acc.currency_code,
        p.amount,
        p.remark
    from transaction.account acc
    join betonmarkets.client cli on acc.client_loginid = cli.loginid
    join payment.payment p on p.account_id = acc.id
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

        my @headers = qw/Broker Loginid Residence Timestamp PaymentGateway PaymentType Currency Amount Remark/;
        {
            my $csv = Text::CSV->new({eol => "\n"});
            $csv->print(\*STDOUT, \@headers);
            while (my $row = $sth->fetchrow_arrayref) {
                s/\s*$// for @$row;    # removes some nasty trailing white-space in historical affiliate records
                $csv->print(\*STDOUT, $row);
            }
        }
    });

1;

