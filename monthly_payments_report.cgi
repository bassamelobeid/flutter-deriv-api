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

my $yyyymm        = $params{yyyymm};
my $broker        = $params{broker};
my $payment_types = $params{payment_type};
my $all_types     = $params{all_payment_types};

my ($yyyy, $mm) = $yyyymm =~ /^(\d{4})-(\d{2})$/;
my $start_date = DateTime->new(
    year  => $yyyy,
    month => $mm
);
my $until_date = $start_date->clone->add(months => 1);

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

my $dbh = BOM::Database::ClientDB->new({
        broker_code => $broker,
    })->db->dbh;

my $sth = $dbh->prepare($sql);
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

1;

