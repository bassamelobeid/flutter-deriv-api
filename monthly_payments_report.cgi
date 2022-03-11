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

my $yyyymm        = $params{yyyymm} // '';
my $broker        = $params{broker} // '';
my $payment_types = $params{payment_type};
my $all_types     = $params{all_payment_types} // '';
my $months        = $params{months}            // 1;

# We construct the download filename from these two values, so let's make sure they're
# sensible before proceeding.
code_exit_BO("Invalid broker code") unless $broker =~ /^[A-Z]{1,6}$/;

my $start_date;
try {
    $yyyymm =~ /^(\d{4})-(\d{2})$/;
    $start_date = Date::Utility->new("$1-$2-01");
} catch {
    code_exit_BO("Date $yyyymm was not parsed as YYYY-MM, check it");
}

my $csv_name = "${broker}_payments_$yyyymm.csv";
$payment_types = [$payment_types] if $payment_types and not ref $payment_types;

if ($all_types or not $payment_types or not @$payment_types) {
    $csv_name      = "${broker}_all_payments_$yyyymm.csv";
    $payment_types = undef;
}

my $dbic = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'backoffice_replica',
    })->db->dbic;

my $rows = $dbic->run(
    fixup => sub {
        $_->selectall_arrayref(
            'SELECT * FROM payment.monthly_payments_report(?,?,?,?)',
            undef,   $broker, $start_date->date_yyyymmdd,
            $months, $payment_types,
        );
    });

PrintContentType_excel($csv_name);

my @headers =
    qw/Broker Loginid Residence Timestamp PaymentGateway PaymentType Currency Amount TransferredAmount TransferedCurrency TransferFee Remark/;

my $csv = Text::CSV->new({eol => "\n"});
$csv->print(\*STDOUT, \@headers);
$csv->print(\*STDOUT, $_) for @$rows;

1;

