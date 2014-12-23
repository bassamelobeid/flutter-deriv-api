#!/usr/bin/perl
package main;

use strict;
use warnings;

use Text::CSV;
use DateTime;

use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType_excel );
use BOM::Platform::Data::Persistence::ConnectionBuilder;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

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
if ($all_types) {
    $payment_filter = '';
    $csv_name       = "${broker}_all_payments_$yyyymm.csv";
} else {
    my @payment_types = ref $payment_types ? @$payment_types : ($payment_types);
    my $payments_string = join(',', map { "'$_'" } @payment_types);
    $payment_filter = "  and p.payment_type_code in ( $payments_string )";
    $csv_name       = "${broker}_payments_$yyyymm.csv";
}

PrintContentType_excel($csv_name);

my $sql = <<HERE;

    select
        cli.broker_code,
        acc.client_loginid,
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
    $payment_filter
    and cli.broker_code = ?   -- b2
    order by 1,2,3

HERE

my $dbh = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
        broker_code => $broker,
        operation   => 'read',
    })->db->dbh;

my $sth   = $dbh->prepare($sql);
my @binds = (
    $start_date->ymd,    # b0
    $until_date->ymd,    # b1
    $broker,             # b2
);
$sth->execute(@binds);

my @headers = qw/Broker Loginid Timestamp PaymentGateway PaymentType Currency Amount Remark/;
{
    my $csv = Text::CSV->new({eol => "\n"});
    $csv->print(\*STDOUT, \@headers);
    while (my $row = $sth->fetchrow_arrayref) {
        s/\s*$// for @$row;    # removes some nasty trailing white-space in historical affiliate records
        $csv->print(\*STDOUT, $row);
    }
}

1;

