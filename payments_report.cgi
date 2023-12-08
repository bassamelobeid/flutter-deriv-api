#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

no indirect;

use Date::Utility;
use Text::CSV;
use Syntax::Keyword::Try;
use BOM::Config::Runtime;
use BOM::Backoffice::PlackHelpers qw( PrintContentType_excel );
use BOM::Database::ClientDB;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my %params = %{request()->params};

my $start_yyyymmdd = $params{start_yyyymmdd} // '';
my $end_yyyymmdd   = $params{end_yyyymmdd}   // '';
my $broker         = $params{broker}         // '';
my $payment_types  = $params{payment_type};
my $all_types      = $params{all_payment_types} // '';
my $months         = $params{months}            // 1;

# We construct the download filename from these two values, so let's make sure they're
# sensible before proceeding.
code_exit_BO("Invalid broker code") unless $broker =~ /^[A-Z]{1,6}$/;

my $start_date;
my $end_date;
try {
    $start_yyyymmdd =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    $start_date = Date::Utility->new("$1-$2-$3");
} catch {
    code_exit_BO("Date $start_yyyymmdd was not parsed as YYYY-MM-DD, check it");
}

try {
    $end_yyyymmdd =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    $end_date = Date::Utility->new("$1-$2-$3");
} catch {
    code_exit_BO("Date $end_yyyymmdd was not parsed as YYYY-MM-DD, check it");
}

my $csv_name = "${broker}_payments_$start_yyyymmdd-$end_yyyymmdd.csv";
$payment_types = [$payment_types] if $payment_types and not ref $payment_types;

if ($all_types or not $payment_types or not @$payment_types) {
    $csv_name      = "${broker}_all_payments_$start_yyyymmdd-$end_yyyymmdd.csv";
    $payment_types = undef;
}

my $dbic = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'backoffice_replica',
    })->db->dbic;

my $rows = $dbic->run(
    fixup => sub {
        $_->selectall_arrayref("
                SELECT * 
                FROM payment.payments_report(
                    ?,
                    date_trunc('day', ?::TIMESTAMP),
                    date_trunc('day', ?::TIMESTAMP) + '1d'::INTERVAL,
                    ?
                    )
                ",
            undef, $broker, $start_date->date_yyyymmdd,
            $end_date->date_yyyymmdd, $payment_types,
        );
    });

PrintContentType_excel($csv_name);

my @headers =
    qw/Broker Loginid Residence Timestamp PaymentGateway PaymentType Currency Amount TransferredAmount TransferedCurrency TransferFee Remark/;

my $csv = Text::CSV->new({eol => "\n"});
$csv->print(\*STDOUT, \@headers);
$csv->print(\*STDOUT, $_) for @$rows;

1;

